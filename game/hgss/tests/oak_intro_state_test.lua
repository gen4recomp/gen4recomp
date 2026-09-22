-- Presentation boundary tests for shared Oak geometry, host input ownership,
-- and disposal. The controller/renderer are conforming test doubles so this
-- suite isolates the LÖVE callback adapter.

local Assert = require("tests.support.Assert")
local OakIntroState = require("game.hgss.src.newgame.OakIntroState")
local OakIntroController = require("game.hgss.src.newgame.OakIntroController")
local NewGame = require("game.hgss.src.newgame.NewGame")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldDialogueController = require("libs.hgss.src.ui.FieldDialogueController")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")

local T = {}
local DIALOGUE_CURSOR_PLACEMENT = { x = 240, y = 168, width = 16, height = 16 }

---@class OakIntroStateTest.Controller
---@field phase string
---@field pressed string[]
---@field text string[]
---@field activated table[]
---@field deleted integer
---@field started integer
---@field disposed integer
---@field choice table?
---@field compositionProgress number
---@field start fun(self: OakIntroStateTest.Controller)
---@field tick fun(self: OakIntroStateTest.Controller, frames: number)
---@field confirmHandoffPresented fun(self: OakIntroStateTest.Controller): boolean
---@field press fun(self: OakIntroStateTest.Controller, action: string)
---@field activateNameCell fun(self: OakIntroStateTest.Controller, row: integer, column: integer): boolean
---@field activateNameControl fun(self: OakIntroStateTest.Controller, id: string): boolean
---@field inputText fun(self: OakIntroStateTest.Controller, text: string)
---@field deleteGlyph fun(self: OakIntroStateTest.Controller)
---@field result fun(self: OakIntroStateTest.Controller): table?
---@field dispose fun(self: OakIntroStateTest.Controller)
---@field view fun(self: OakIntroStateTest.Controller): table
---@field messageCompleted fun(self: OakIntroStateTest.Controller, key: string): boolean
---@class OakIntroStateTest.Input: OakIntroStateTextInputHost
---@field calls boolean[]
---@field setTextInput fun(self: OakIntroStateTest.Input, enabled: boolean)
---@class OakIntroStateTest.Renderer: OakIntroStateRenderer
---@field draws integer
---@field disposed integer
---@field draw fun(self: OakIntroStateTest.Renderer, view: table, overlay: function?)
---@field dispose fun(self: OakIntroStateTest.Renderer)

local INTRO_MANIFEST = {
  schemaVersion = 9,
  sourceReference = { width = 256, height = 192 },
  genderSelector = {
    defaultTone = { r = 100, g = 101, b = 102 },
    buttons = {
      male = {
        bounds = { x = 18, y = 25, width = 93, height = 148 },
      },
      female = {
        bounds = { x = 144, y = 25, width = 95, height = 148 },
      },
    },
  },

  background = { width = 256, height = 192, sampling = "linear" },
  widgets = {
    oak = {
      width = 80,
      height = 100,
      anchor = { x = 20, y = 100 },
      sourceBounds = { x = 40, y = 30, width = 80, height = 100 },
    },
    male = {
      width = 64,
      height = 96,
      anchor = { x = 32, y = 48 },
      sourceBounds = { x = 0, y = 0, width = 64, height = 96 },
    },
    female = {
      width = 64,
      height = 96,
      anchor = { x = 32, y = 48 },
      sourceBounds = { x = 0, y = 0, width = 64, height = 96 },
    },
    gender_male = {
      width = 64,
      height = 96,
      anchor = { x = 32, y = 48 },
      sourceBounds = { x = 0, y = 0, width = 64, height = 96 },
      sourceCenter = { x = 64, y = 104 },
    },
    gender_female = {
      width = 64,
      height = 96,
      anchor = { x = 32, y = 48 },
      sourceBounds = { x = 0, y = 0, width = 64, height = 96 },
      sourceCenter = { x = 192, y = 104 },
    },
    ball_open = {
      width = 40,
      height = 30,
      anchor = { x = 20, y = 30 },
      sourceBounds = { x = 140, y = 50, width = 40, height = 30 },
      sourceCenter = { x = 160, y = 80 },
    },
    marill_appear = {
      width = 40,
      height = 30,
      anchor = { x = 20, y = 30 },
      sourceBounds = { x = 140, y = 50, width = 40, height = 30 },
      sourceCenter = { x = 160, y = 80 },
    },
    marill = {
      width = 40,
      height = 30,
      anchor = { x = 20, y = 30 },
      sourceBounds = { x = 140, y = 50, width = 40, height = 30 },
      sourceCenter = { x = 160, y = 80 },
    },
    confirmation_yes = {
      width = 115,
      height = 57,
      anchor = { x = 0, y = 0 },
      sourceBounds = { x = 138, y = 26, width = 115, height = 57 },
      contentRect = { x = 6, y = 22, width = 104, height = 24 },
    },
    confirmation_no = {
      width = 115,
      height = 56,
      anchor = { x = 0, y = 0 },
      sourceBounds = { x = 138, y = 108, width = 115, height = 56 },
      contentRect = { x = 6, y = 20, width = 104, height = 24 },
    },
  },
}

---@return OakIntroStateTest.Controller
local function fakeController()
  local controller = {
    phase = "name_edit",
    pressed = {},
    text = {},
    activated = {},
    deleted = 0,
    started = 0,
    disposed = 0,
    choice = nil,
    compositionProgress = 1,
  }
  function controller:start()
    self.started = self.started + 1
  end
  function controller:tick() end
  function controller:confirmHandoffPresented()
    return false
  end
  function controller:press(action)
    self.pressed[#self.pressed + 1] = action
  end
  function controller:inputText(text)
    self.text[#self.text + 1] = text
  end
  function controller:deleteGlyph()
    self.deleted = self.deleted + 1
  end
  function controller:activateNameCell(row, column)
    self.activated[#self.activated + 1] = { row = row, column = column }
    if row == 1 and column == 3 then
      self.text[#self.text + 1] = "é"
    end
    return true
  end
  function controller:activateNameControl(id)
    self.activated[#self.activated + 1] = { control = id }
    return true
  end
  function controller:result()
    return nil
  end
  function controller:dispose()
    self.disposed = self.disposed + 1
  end
  function controller:view()
    return {
      phase = self.phase,
      genderCompositionProgress = self.compositionProgress,
      name = "A",
      nameInputEnabled = self.phase == "name_edit",
      genderFocus = 0,
      message = "generated.message",
      visual = "background",
      finalFadeAlpha = 0,
      namingScreen = {
        page = "upper",
        text = "A",
        cursor = { row = 1, column = 1 },
        grid = {
          { { kind = "glyph", glyph = "A" }, { kind = "glyph", glyph = "B" }, { kind = "glyph", glyph = "é" } },
          {},
          {},
          {},
          {},
          {},
        },
        subject = { kind = "player", gender = 0 },
      },
      confirmationChoice = self.choice,
    }
  end
  return controller --[[@as OakIntroStateTest.Controller]]
end

local function stateHarness(overrides)
  local controller = fakeController()
  local input = { calls = {} }
  ---@cast input OakIntroStateTest.Input
  function input:setTextInput(enabled)
    self.calls[#self.calls + 1] = enabled
  end
  local renderer = { draws = 0, disposed = 0 }
  ---@cast renderer OakIntroStateTest.Renderer
  function renderer:draw(_, overlay)
    self.draws = self.draws + 1
    if overlay then
      overlay()
    end
  end
  function renderer:dispose()
    self.disposed = self.disposed + 1
  end
  local choiceText = { releases = 0 }
  function choiceText:release()
    self.releases = self.releases + 1
  end
  local state = OakIntroState.new({
    controller = controller --[[@as OakIntroController]],
    manifest = INTRO_MANIFEST,
    textRenderer = {},
    choiceText = choiceText,
    renderer = renderer,
    textInputHost = input,
    dialogueFormatter = {
      format = function(_, key)
        return { tokens = {}, text = key, hadUnresolvedSubstitutions = false }
      end,
      choiceLabels = function()
        return { [0] = "YES", [1] = "NO" }
      end,
    },
    glyphs = { "A", "B", "é" },
    width = 640,
    height = 480,
    namingOverrides = overrides,
    dialogueCursorPlacement = DIALOGUE_CURSOR_PLACEMENT,
  })
  return state, controller, input, renderer, choiceText
end

function T.text_input_is_owned_only_by_the_name_editor_and_released_on_dispose()
  local state, controller, input, renderer = stateHarness()
  Assert.deepEqual(input.calls, { false })
  state:textinput("é")
  Assert.deepEqual(input.calls, { false, true })
  Assert.deepEqual(controller.text, { "é" })
  controller.phase = "gender_select"
  state:update(0)
  Assert.deepEqual(input.calls, { false, true, false })
  state:dispose()
  Assert.deepEqual(input.calls, { false, true, false })
  Assert.equal(controller.disposed, 1)
  Assert.equal(renderer.disposed, 1)
end

function T.naming_session_disposes_with_the_state_and_releases_input_once()
  local state, controller = stateHarness()
  controller.phase = "name_edit"
  local view = state:view()
  Assert.notNil(view.namingPresentation, "name editing publishes its parent-owned naming plan")
  state:dispose()
  state:dispose()
  Assert.equal(controller.disposed, 1, "the profile controller disposes exactly once")
end

function T.invalid_naming_override_fails_without_a_partial_plan()
  local badState, badController = stateHarness({ sideways = function(_, _) end })
  badController.phase = "name_edit"
  Assert.throws(function()
    badState:view()
  end, "an unknown naming override case fails before publication")
end

function T.naming_reflow_keeps_the_session_without_stale_activation()
  local state, controller = stateHarness()
  controller.phase = "name_edit"
  local view = state:view()
  local plan = assert(view.namingPresentation, "name editing publishes its parent-owned naming plan")
  local pane = assert(plan.panes[1], "the naming plan carries its content pane")
  local placement = assert(pane.placement, "the naming pane carries its host placement")
  local naming = assert(view.layout.namingScreen, "name editing publishes the canonical Naming Screen")
  local key = naming.cells[2][1]
  local x, y = LayoutGeometry.logicalToHost(placement, key.x + 1, key.y + 1)
  state:mousepressed(x, y, 1)
  Assert.deepEqual(controller.activated, { { row = 2, column = 1 } })
  state:resize(960, 720)
  local reframed = state:view()
  Assert.notNil(reframed.namingPresentation, "the naming session survives the geometry change")
  state:mousepressed(10, 10, 1)
  Assert.deepEqual(
    controller.activated,
    { { row = 2, column = 1 } },
    "matte outside the reframed pane never enters the editor"
  )
  local fresh = state:view()
  local freshPlan = assert(fresh.namingPresentation, "the naming plan resolves after reflow")
  local freshPane = assert(freshPlan.panes[1], "the reframed plan carries its content pane")
  local freshKey = assert(fresh.layout.namingScreen, "reflow keeps the canonical Naming Screen").cells[2][1]
  local fx, fy = LayoutGeometry.logicalToHost(
    assert(freshPane.placement, "the reframed pane carries its host placement"),
    freshKey.x + 1,
    freshKey.y + 1
  )
  state:mousepressed(fx, fy, 1)
  Assert.deepEqual(controller.activated, { { row = 2, column = 1 }, { row = 2, column = 1 } })
  state:mousereleased(fx, fy, 1)
end

-- Blur must end any held naming gesture: a stale move/release after
-- focus loss moves nothing and activates nothing, while a fresh press
-- afterwards still works. Blur outside the editor stays a no-op.
function T.held_naming_gesture_ends_on_focus_loss_and_fresh_input_recovers()
  local state, controller = stateHarness()
  controller.phase = "name_edit"
  state:resize(1280, 720)
  local plan = assert(state:view().namingPresentation, "name editing publishes its naming plan")
  local window = assert(plan.window, "a wide host must frame naming in a window")
  local grab = assert(window.grabRect, "the naming window must carry its grab strip")
  local frame0 = assert(window.outer, "the naming window must carry its outer placement").frame
  local grabX, grabY = grab.x + grab.width / 2, grab.y + grab.height / 2
  state:mousepressed(grabX, grabY, 1)
  state:focus(false)
  state:focus(true)
  state:mousemoved(grabX + 40, grabY, 0, 0, false)
  state:mousereleased(grabX + 40, grabY, 1)
  local held = assert(state:view().namingPresentation, "the naming plan survives the blur").window.outer.frame
  Assert.deepEqual(
    { x = held.x, y = held.y },
    { x = frame0.x, y = frame0.y },
    "a stale move after blur must not continue the old drag"
  )
  state:mousepressed(grabX, grabY, 1)
  state:mousemoved(grabX + 40, grabY, 0, 0, false)
  local moved = assert(state:view().namingPresentation, "the naming plan survives a fresh drag").window.outer.frame
  Assert.isTrue(moved.x > frame0.x, "a fresh drag works after refocus")
  state:mousereleased(grabX + 40, grabY, 1)

  local fresh = state:view()
  local freshPlan = assert(fresh.namingPresentation, "the naming plan resolves after the fresh drag")
  local freshPane = assert(freshPlan.panes[1], "the plan carries its content pane")
  local naming = assert(fresh.layout.namingScreen, "name editing publishes the canonical Naming Screen")
  local key = naming.cells[2][1]
  local keyX, keyY = LayoutGeometry.logicalToHost(
    assert(freshPane.placement, "the pane carries its host placement"),
    key.x + 1,
    key.y + 1
  )
  state:mousepressed(keyX, keyY, 1)
  Assert.deepEqual(controller.activated, { { row = 2, column = 1 } })
  state:focus(false)
  state:focus(true)
  state:mousereleased(keyX, keyY, 1)
  Assert.deepEqual(
    controller.activated,
    { { row = 2, column = 1 } },
    "a stale release after blur must not activate the cell twice"
  )
  state:mousepressed(keyX, keyY, 1)
  Assert.deepEqual(
    controller.activated,
    { { row = 2, column = 1 }, { row = 2, column = 1 } },
    "a fresh cell press still activates after refocus"
  )
  state:mousereleased(keyX, keyY, 1)

  controller.phase = "gender_select"
  state:focus(false)
  state:focus(true)
  Assert.isNil(state:view().namingPresentation, "blur outside the editor publishes no naming plan")
  local genderLayout = state:view().layout
  local genderX, genderY = LayoutGeometry.logicalToHost(
    assert(state:view().pixelSurface).placement,
    genderLayout.genderButtons[1].rect.x + genderLayout.genderButtons[1].rect.width / 2,
    genderLayout.genderButtons[1].rect.y + genderLayout.genderButtons[1].rect.height / 2
  )
  state:mousepressed(genderX, genderY, 1)
  Assert.deepEqual(controller.pressed, { "female" }, "blur outside the editor changes nothing")
end

function T.pointer_hits_the_same_drawn_virtual_key_geometry()
  local state, controller = stateHarness()
  local view = state:view()
  local plan = assert(view.namingPresentation, "name editing publishes its parent-owned naming plan")
  local pane = assert(plan.panes[1], "the naming plan carries its content pane")
  local naming = assert(view.layout.namingScreen, "name editing publishes the canonical Naming Screen")
  local key = naming.cells[2][1]
  local x, y = LayoutGeometry.logicalToHost(
    assert(pane.placement, "the naming pane carries its host placement"),
    key.x + 1,
    key.y + 1
  )
  state:mousepressed(x, y, 1)
  Assert.deepEqual(controller.activated, { { row = 2, column = 1 } })
  state:mousereleased(x, y, 1)
  local control = naming.controls.upper
  local cx, cy = LayoutGeometry.logicalToHost(
    assert(pane.placement, "the naming pane carries its host placement"),
    control.x + 1,
    control.y + 1
  )
  state:mousepressed(cx, cy, 1)
  Assert.deepEqual(controller.activated, { { row = 2, column = 1 }, { control = "upper" } })
  state:mousereleased(cx, cy, 1)
end

function T.pointer_mapping_uses_the_logical_surface_for_name_and_gender_controls()
  local state, controller = stateHarness()
  state:resize(641, 481)
  local nameView = state:view()
  local surface = assert(nameView.pixelSurface)
  Assert.equal(surface.placement.scale, 2)
  Assert.equal(surface.logicalViewport.width, 320.5)
  Assert.equal(surface.logicalViewport.height, 240.5)
  Assert.equal(nameView.layout.viewport.width, surface.logicalViewport.width)
  Assert.equal(nameView.layout.viewport.height, surface.logicalViewport.height)

  local naming = assert(nameView.layout.namingScreen)
  local namingPlan = assert(nameView.namingPresentation, "name editing publishes its parent-owned naming plan")
  local namingPane = assert(namingPlan.panes[1], "the naming plan carries its content pane")
  local key = assert(naming.cells[2][1])
  local keyX, keyY = LayoutGeometry.logicalToHost(
    assert(namingPane.placement, "the naming pane carries its host placement"),
    key.x + 1,
    key.y + 1
  )
  state:mousepressed(keyX, keyY, 1)
  Assert.deepEqual(controller.activated, { { row = 2, column = 1 } })

  controller.phase = "gender_select"
  local genderView = state:view()
  local gender = assert(genderView.layout.genderButtons[1])
  local genderX = gender.rect.x + gender.rect.width / 2
  local genderY = gender.rect.y + gender.rect.height / 2
  local hostX, hostY = LayoutGeometry.logicalToHost(surface.placement, genderX, genderY)
  state:mousepressed(hostX, hostY, 1)
  Assert.deepEqual(controller.pressed, { "female" })

  state:mousepressed(surface.placement.frame.x + surface.placement.frame.width + 1, hostY, 1)
  Assert.deepEqual(controller.pressed, { "female" }, "physical points outside the frame must not activate controls")
end

function T.wide_host_view_keeps_responsive_metrics_on_the_physical_grid()
  local state, controller = stateHarness()
  controller.phase = "gender_select"
  state:resize(1710, 895)
  local view = state:view()
  local surface = assert(view.pixelSurface)
  local layout = assert(view.layout)
  Assert.equal(surface.placement.scale, 4)
  Assert.equal(layout.safeFrame.x * surface.placement.scale, 12)
  Assert.equal(layout.stageContent.width * surface.placement.scale, 1120)
  Assert.isNil(layout.subject, "Oak must be absent while the selector is shown")
  Assert.isNil(layout.oakRegion, "Oak must be absent while the selector is shown")
  Assert.notNil(layout.selectorRegion, "gender selection must publish a selector region")
end

function T.pointer_hits_the_same_button_geometry_used_by_presentation()
  local state, controller = stateHarness()
  controller.phase = "gender_select"
  local genderLayout = state:view().layout
  local genderX, genderY = LayoutGeometry.logicalToHost(
    assert(state:view().pixelSurface).placement,
    genderLayout.genderButtons[1].rect.x + genderLayout.genderButtons[1].rect.width / 2,
    genderLayout.genderButtons[1].rect.y + genderLayout.genderButtons[1].rect.height / 2
  )
  state:mousepressed(genderX, genderY, 1)
  Assert.deepEqual(controller.pressed, { "female" })

  controller.phase = "gender_confirm"
  controller.choice = { kind = "gender", selected = 0 }
  local layout = state:view().layout
  Assert.isNil(layout.genderButtons)
  local profileX, profileY = LayoutGeometry.logicalToHost(
    assert(state:view().pixelSurface).placement,
    layout.selectedProfileButton.rect.x + layout.selectedProfileButton.rect.width / 2,
    layout.selectedProfileButton.rect.y + layout.selectedProfileButton.rect.height / 2
  )
  state:mousepressed(profileX, profileY, 1)
  Assert.deepEqual(controller.pressed, { "female" })
  local yesX, yesY = LayoutGeometry.logicalToHost(
    assert(state:view().pixelSurface).placement,
    layout.confirmationButtons[0].rect.x + 1,
    layout.confirmationButtons[0].rect.y + 1
  )
  local noX, noY = LayoutGeometry.logicalToHost(
    assert(state:view().pixelSurface).placement,
    layout.confirmationButtons[1].rect.x + 1,
    layout.confirmationButtons[1].rect.y + 1
  )
  state:mousepressed(yesX, yesY, 1)
  state:mousepressed(noX, noY, 1)
  Assert.deepEqual(controller.pressed, { "female", "yes", "no" })
end

function T.pointer_cannot_activate_gender_selection_during_host_composition()
  local state, controller = stateHarness()
  controller.phase = "name_launch_wait"
  local layout = state:view().layout
  Assert.isNil(layout.genderButtons)
  state:mousepressed(320, 240, 1)
  state:touchpressed(1, 320, 240)
  Assert.deepEqual(controller.pressed, {})
end

function T.keyboard_and_gamepad_use_one_controller_buffer_path()
  local state, controller = stateHarness()
  state:keypressed("right")
  state:gamepadpressed({}, "a")
  state:keypressed("backspace")
  Assert.deepEqual(controller.pressed, { "right", "confirm", "cancel" })
  Assert.equal(controller.deleted, 0, "cancel keys delete through press, not the direct glyph path")
  Assert.deepEqual(controller.text, {})
end

function T.gamepad_confirm_uses_the_focused_semantic_key()
  local state, controller = stateHarness()
  state:gamepadpressed(nil, "a")
  controller.phase = "gender_select"
  state:gamepadpressed(nil, "a")
  Assert.deepEqual(controller.pressed, { "confirm", "confirm" })
end

function T.confirm_capable_keys_activate_the_focused_virtual_key_like_gamepad_a()
  local state, controller = stateHarness()
  Assert.equal(controller.phase, "name_edit")
  state:keypressed("return")
  state:keypressed("kpenter")
  state:keypressed("space")
  state:gamepadpressed(nil, "a")
  Assert.deepEqual(
    controller.pressed,
    { "confirm", "confirm", "confirm", "confirm" },
    "keyboard Enter/KPEnter/Space confirm the focused naming target like gamepad A; only Start submits"
  )
end

-- A consumed action-key press never becomes literal text: Space confirms the
-- focused naming target through keypressed, so textinput must not also
-- insert a space glyph, while direct typing of other glyphs still inserts.
function T.consumed_action_key_text_never_inserts_a_literal_space_or_newline()
  local state, controller = stateHarness()
  Assert.equal(controller.phase, "name_edit")
  state:textinput(" ")
  state:textinput("\n")
  state:textinput("\r")
  Assert.deepEqual(controller.text, {}, "consumed Space/Return text never inserts a literal glyph")
  state:textinput("é")
  Assert.deepEqual(controller.text, { "é" }, "direct typing of other glyphs still inserts")
end

-- Physical action keys confirm the focused naming cell like gamepad A:
-- they activate the focused glyph or control instead of submitting, while
-- cancel keys delete one glyph and Start submits. Removed aliases stay inert.
function T.physical_action_cancel_and_start_follow_naming_semantics()
  local state, controller = stateHarness()
  Assert.equal(controller.phase, "name_edit")
  state:keypressed("space")
  state:keypressed("return")
  state:keypressed("kpenter")
  Assert.deepEqual(
    controller.pressed,
    { "confirm", "confirm", "confirm" },
    "Space/Return/KPEnter confirm the focused naming target instead of submitting"
  )
  state:keypressed("backspace")
  state:keypressed("delete")
  state:keypressed("escape")
  Assert.deepEqual(
    controller.pressed,
    { "confirm", "confirm", "confirm", "cancel", "cancel", "cancel" },
    "Backspace/Delete/Escape delete one glyph through the naming cancel path"
  )
  local before = #controller.pressed
  state:keypressed("z")
  state:keypressed("x")
  state:keypressed("m")
  Assert.equal(#controller.pressed, before, "removed keyboard aliases never reach the naming controller")
  state:gamepadpressed(nil, "start")
  Assert.deepEqual(controller.pressed[#controller.pressed], "start", "Start submits regardless of the focused cell")
end

function T.a_held_confirm_key_does_not_repeat_activation()
  local state, controller = stateHarness()
  state:keypressed("return", "return", false)
  state:keypressed("return", "return", true)
  state:keypressed("return", "return", true)
  Assert.deepEqual(
    controller.pressed,
    { "confirm" },
    "a held physical key must not activate the focused virtual key more than once"
  )
end

function T.audio_lifetime_is_released_once_with_the_state()
  local state, controller, _, renderer = stateHarness()
  local lifetime = { releases = 0 }
  function lifetime:dispose()
    self.releases = self.releases + 1
  end
  state.audioLifetime = lifetime

  state:dispose()
  state:dispose()

  Assert.equal(lifetime.releases, 1)
  Assert.equal(controller.disposed, 1)
  Assert.equal(renderer.disposed, 1)
end

function T.choice_text_renderer_is_released_once_with_the_state()
  local state, _, _, _, choiceText = stateHarness()
  state:dispose()
  state:dispose()
  Assert.equal(choiceText.releases, 1)
end

function T.shared_dialogue_stack_is_advanced_and_drawn_by_the_state()
  local state, controller = stateHarness()
  local dialogue = {
    opened = 0,
    stepped = 0,
    drawn = 0,
    released = 0,
    open = function(self)
      self.opened = self.opened + 1
      return { onComplete = function() end }
    end,
    step = function(self, input)
      self.stepped = self.stepped + 1
      self.lastInput = input
    end,
    isModal = function()
      return true
    end,
    status = function()
      return {}
    end,
    draw = function(self, presentation)
      self.drawn = self.drawn + 1
      self.presentation = presentation
    end,
    dispose = function(self)
      self.released = self.released + 1
    end,
  }
  state.dialogueController = dialogue
  state.dialogueRenderer = dialogue
  state.dialoguePresentation = nil
  controller.phase = "oak_welcome"
  controller.view = function(self)
    return {
      phase = self.phase,
      messageKey = "oak.welcome",
      message = { tokens = {} },
      name = "",
      nameInputEnabled = false,
      genderFocus = 0,
      visual = "background",
    }
  end
  state:_sync()
  Assert.equal(dialogue.opened, 1)
  state:tick(1)
  Assert.equal(dialogue.stepped, 1)
  state:draw()
  Assert.equal(dialogue.drawn, 1)
  Assert.notNil(dialogue.presentation, "Oak passes its compact dialogue presentation to the shared renderer")
  state:dispose()
  Assert.equal(dialogue.released, 1)
end

-- Real-controller fixtures below drive `OakIntroState` through its actual
-- `update`/`draw` boundary, the same seam the running game uses.

local SHRINK_MANIFEST = {
  schemaVersion = 7,
  sourceReference = INTRO_MANIFEST.sourceReference,
  background = INTRO_MANIFEST.background,
  widgets = {
    oak = INTRO_MANIFEST.widgets.oak,
    gender_male = INTRO_MANIFEST.widgets.gender_male,
    gender_female = INTRO_MANIFEST.widgets.gender_female,
    male = {
      width = 96,
      height = 120,
      anchor = { x = 48, y = 120 },
      sourceBounds = { x = 36, y = 24, width = 96, height = 120 },
    },
    shrink_male = {
      width = 44,
      height = 68,
      anchor = { x = 22, y = 68 },
      sourceBounds = { x = 142, y = 70, width = 44, height = 68 },
    },
  },
}

local SHRINK_PLAYER_DATA_CONTEXT = {
  charmap = { A = 1, B = 2, C = 3, D = 4, E = 5, F = 6, G = 7, O = 8, L = 9, [" "] = 10 },
  frameIndexes = { [0] = true },
}

local SHRINK_MESSAGES = {
  ["greeting.day"] = "greeting.day",
  ["oak.welcome"] = "oak.welcome",
  ["oak.world_inhabited"] = "oak.world_inhabited",
  ["oak.live_alongside"] = "oak.live_alongside",
  ["oak.tell_about_yourself"] = "oak.tell_about_yourself",
  ["profile.gender_question"] = "profile.gender_question",
  ["profile.gender_confirm.male"] = "profile.gender_confirm.male",
  ["profile.name_prompt"] = "profile.name_prompt",
  ["profile.name_confirm.male"] = "profile.name_confirm.male",
  ["profile.final"] = "profile.final",
}

local function silentAudio()
  return {
    playMusic = function() end,
    stopMusic = function() end,
    fadeMusicOut = function() end,
    play = function() end,
    playCry = function() end,
    updateSoundFrame = function() end,
    isMusicFadeActive = function()
      return false
    end,
  }
end

local function fixedClock()
  return {
    nowLocal = function()
      return { year = 2026, month = 8, day = 22, hour = 12, minute = 0, second = 0 }
    end,
  }
end

local function realCandidate()
  return NewGame.createCandidate({
    saveService = {
      reserve = function()
        return "save-00000099"
      end,
    },
    versionId = "heartgold",
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

local function shrinkFrames(duration, count)
  local frames = {}
  for index = 1, count do
    frames[index] = { duration = duration }
  end
  return { frames = frames }
end

local function completeActiveMessage(controller)
  local key = assert(controller:view().messageKey, "Oak state test expected an active message")
  return controller:messageCompleted(key)
end

-- Builds a real controller/state pair and drives it through the semantic
-- confirm presses used by production input mapping to the instant
-- `final_full_art_hold` is freshly entered with its 30-source-tick timer
-- untouched. The scenario body then drives the host-timed update boundary.
local function stateAtFreshFullArtHold(frameDuration, frameCount)
  local controller = OakIntroController.new({
    candidate = realCandidate(),
    clock = fixedClock(),
    audio = silentAudio() --[[@as GameSound]],
    messages = SHRINK_MESSAGES,
    assets = {
      marill = { playMode = "forward_loop", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
      marill_appear = { playMode = "forward", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
      ball_open = { playMode = "forward", loopStartFrameIdx = 0, frames = { { duration = 1 } } },
      male = { frames = { { duration = 1 } } },
      shrink_male = shrinkFrames(frameDuration, frameCount),
    },
    playerDataContext = SHRINK_PLAYER_DATA_CONTEXT,
    randomU32 = function()
      return 0x12345678
    end,
  })

  local recorded = {}
  local renderer = {
    draw = function(_, view)
      recorded[#recorded + 1] = {
        phase = view.phase,
        visual = view.visual,
        frameIndex = view.visualFrameIndex,
        finalFadeAlpha = view.finalFadeAlpha,
      }
    end,
    dispose = function() end,
  }
  local state = OakIntroState.new({
    controller = controller,
    manifest = SHRINK_MANIFEST,
    textRenderer = {},
    choiceText = { release = function() end },
    renderer = renderer,
    glyphs = { "A", "B", "C", "D", "E", "F", "G", "O", "L" },
    width = 640,
    height = 480,
  })

  state:tick(40)
  completeActiveMessage(controller)
  state:tick(6 + 30)
  completeActiveMessage(controller)
  state:tick(26)
  completeActiveMessage(controller)
  while controller:view().phase ~= "oak_live_alongside" do
    state:tick(1)
  end
  completeActiveMessage(controller)
  while controller:view().phase ~= "oak_tell_about_yourself" do
    state:tick(1)
  end
  completeActiveMessage(controller)
  completeActiveMessage(controller)
  state:tick(26)
  controller:press("confirm")
  completeActiveMessage(controller)
  controller:press("confirm")
  completeActiveMessage(controller)
  state:tick(40)
  controller:inputText("GOLD")
  controller:press("submit")
  state:tick(26)
  completeActiveMessage(controller)
  controller:press("confirm")
  completeActiveMessage(controller)
  Assert.equal(controller:view().phase, "final_fade_out")
  state:tick(1)
  Assert.equal(controller:view().phase, "final_full_art_fade_in")
  state:tick(1)
  Assert.equal(controller:view().phase, "final_full_art_hold")

  return state, controller, recorded
end

-- A normal 1/30 update/draw cadence preserves the exact 30-source-tick hold
-- and nine-source-tick-per-frame shrink cadence at the draw-visible
-- boundary.
function T.source_timed_update_draw_cadence_preserves_full_art_hold_and_shrink_frame_durations()
  local state, controller, recorded = stateAtFreshFullArtHold(9, 4)

  -- The setup above reaches the hold's freshly entered state through the
  -- frame-counted `tick` helper, which draws nothing; include that initial
  -- hold view before the first source-timed update.
  state:draw()

  for _ = 1, 30 + 9 * 4 + 6 do
    state:update(1 / 30)
    state:draw()
  end

  local holdDraws = 0
  for _, entry in ipairs(recorded) do
    if entry.phase == "final_full_art_hold" then
      holdDraws = holdDraws + 1
    end
  end
  Assert.equal(holdDraws, 30, "full profile art must remain draw-visible for exactly 30 source ticks")

  for frameIndex = 1, 4 do
    local draws = 0
    for _, entry in ipairs(recorded) do
      if entry.phase == "shrink_animation" and entry.frameIndex == frameIndex then
        draws = draws + 1
      end
    end
    Assert.equal(draws, 9, "each generated shrink frame must remain draw-visible for exactly nine source ticks")
  end

  Assert.isTrue(
    controller:view().phase ~= "complete",
    "reaching full black must wait for the presented draw, not complete"
  )
  Assert.isNil(controller:result(), "the candidate stays unpublished until the black frame is presented")
  Assert.near(controller:view().finalFadeAlpha, 1, 1e-9, "the waiting cover stays black")

  -- The loop above ends with the presented full-black draw, so exactly one
  -- more update acknowledges that presentation and completes the handoff.
  state:update(1 / 30)
  Assert.equal(controller:view().phase, "complete")
end

function T.thirty_source_frame_hold_uses_one_second_host_time()
  local state, controller = stateAtFreshFullArtHold(9, 4)
  local holdStart = controller:view().sourceFrames

  for _ = 1, 29 do
    state:update(1 / 30)
    Assert.equal(controller:view().phase, "final_full_art_hold")
  end
  Assert.equal(controller:view().sourceFrames - holdStart, 29)

  state:update(1 / 30)

  Assert.equal(controller:view().sourceFrames - holdStart, 30)
  Assert.equal(controller:view().phase, "shrink_animation")
  Assert.equal(controller:view().visualFrameIndex, 1)
end

local function semanticSnapshot(controller)
  local view = controller:view()
  return {
    sourceFrames = view.sourceFrames,
    phase = view.phase,
    visual = view.visual,
    visualFrameIndex = view.visualFrameIndex,
    result = controller:result(),
  }
end

-- A host update that contains many source frames must have the same semantic
-- result as advancing those source frames directly, including transitions
-- across the full-art hold and several generated shrink frames.
function T.large_host_update_matches_equivalent_source_ticks()
  local state, controller = stateAtFreshFullArtHold(9, 4)
  local referenceState, referenceController = stateAtFreshFullArtHold(9, 4)

  state:update(52 / 30)
  referenceState:tick(52)

  Assert.deepEqual(
    semanticSnapshot(controller),
    semanticSnapshot(referenceController),
    "a large host update must drain the same source frames as the deterministic tick helper"
  )
end

function T.sub_source_frame_update_does_not_advance_the_controller()
  local state, controller = stateAtFreshFullArtHold(9, 4)
  local sourceFrames = controller:view().sourceFrames

  state:update(1 / 30 - 1e-13)

  Assert.equal(controller:view().sourceFrames, sourceFrames)
end

function T.two_half_source_frame_updates_drain_one_controller_tick()
  local state, controller = stateAtFreshFullArtHold(9, 4)
  local sourceFrames = controller:view().sourceFrames
  local halfSourceFrame = (1 / 30) / 2

  state:update(halfSourceFrame)
  Assert.equal(controller:view().sourceFrames, sourceFrames)

  state:update(halfSourceFrame)
  Assert.equal(controller:view().sourceFrames, sourceFrames + 1)
end

-- Drives a real controller/state pair from a fresh full-art hold through the
-- shrink into the post-shrink cover, leaving exactly one source tick before
-- full black (cover coefficient 13/16).
local function stateAtCoverPenultimateTick()
  local state, controller, recorded = stateAtFreshFullArtHold(9, 4)
  state:tick(30 + 9 * 4 + 5)
  Assert.near(controller:view().finalFadeAlpha, 13 / 16, 1e-9, "the cover must be one tick from full black")
  Assert.isTrue(controller:view().phase ~= "complete")
  Assert.isNil(controller:result())
  return state, controller, recorded
end

-- Reaching full black must not complete: only a successfully drawn black
-- frame, acknowledged on a later update, may publish the finalized candidate.
function T.full_black_handoff_completes_only_after_a_presented_draw()
  local state, controller, recorded = stateAtCoverPenultimateTick()
  local completions = 0
  state.onComplete = function()
    completions = completions + 1
  end

  state:tick(1)
  Assert.near(controller:view().finalFadeAlpha, 1, 1e-9, "the cover must reach full black")
  Assert.isTrue(controller:view().phase ~= "complete", "full black must wait for presentation, not complete")
  Assert.isNil(controller:result(), "the candidate must stay unpublished until the black frame is presented")
  Assert.equal(completions, 0)

  state:tick(20)
  Assert.isTrue(controller:view().phase ~= "complete", "ticks without a draw must not complete")
  Assert.isNil(controller:result())
  Assert.equal(completions, 0)

  local drawsBefore = #recorded
  state:draw()
  Assert.equal(#recorded, drawsBefore + 1, "the waiting black frame must be drawn")
  local presented = recorded[#recorded]
  Assert.near(presented.finalFadeAlpha, 1, 1e-9, "the presented handoff draw must be fully black")
  Assert.isTrue(presented.phase ~= "complete", "the presented draw must still be Oak-owned")
  Assert.isTrue(controller:view().phase ~= "complete", "drawing must not itself complete the handoff")
  Assert.equal(completions, 0, "drawing must not invoke completion; the next update does")

  state:tick(1)
  Assert.equal(controller:view().phase, "complete")
  Assert.notNil(controller:result())
  Assert.equal(completions, 1)
end

-- Only a successful draw unlocks the handoff: a failed full-black draw must
-- leave the controller waiting exactly as if no draw had happened.
function T.failed_full_black_draw_does_not_unlock_completion()
  local state, controller, recorded = stateAtCoverPenultimateTick()
  local completions = 0
  state.onComplete = function()
    completions = completions + 1
  end

  state:tick(1)
  Assert.near(controller:view().finalFadeAlpha, 1, 1e-9, "the cover must reach full black")
  Assert.isTrue(controller:view().phase ~= "complete")

  local presentedDraw = state.renderer.draw
  state.renderer.draw = function()
    error("synthetic full-black draw failure", 0)
  end
  Assert.throws(function()
    state:draw()
  end, "a failing renderer must surface its draw failure")
  state.renderer.draw = presentedDraw

  state:tick(1)
  Assert.isTrue(controller:view().phase ~= "complete", "a failed draw must not unlock completion")
  Assert.isNil(controller:result())
  Assert.equal(completions, 0)

  state:draw()
  local presented = recorded[#recorded]
  Assert.near(presented.finalFadeAlpha, 1, 1e-9, "the recovery draw must present the full-black frame")
  state:tick(1)
  Assert.equal(controller:view().phase, "complete")
  Assert.equal(completions, 1)
end

-- A single host update large enough to cross the final fade boundary must stop
-- at the full-black wait: reaching black and consuming the presentation
-- barrier cannot happen in the same update loop without a draw in between.
function T.large_host_update_stops_at_full_black_without_a_draw()
  local state, controller, _ = stateAtCoverPenultimateTick()
  local completions = 0
  state.onComplete = function()
    completions = completions + 1
  end

  state:update(10 / 30)
  Assert.near(controller:view().finalFadeAlpha, 1, 1e-9, "the large update must still reach full black")
  Assert.isTrue(controller:view().phase ~= "complete", "a large host update must stop at the full-black wait")
  Assert.isNil(controller:result(), "the candidate must stay unpublished without a presented draw")
  Assert.equal(completions, 0)

  state:update(10 / 30)
  Assert.isTrue(controller:view().phase ~= "complete", "repeated updates without a draw must keep waiting")
  Assert.isNil(controller:result())
  Assert.equal(completions, 0)
  Assert.near(controller:view().finalFadeAlpha, 1, 1e-9, "the waiting cover stays black")
end

function T.completion_preserves_unconsumed_host_time_and_hands_off_once()
  local state, controller = stateAtFreshFullArtHold(9, 4)
  local completions = 0
  state.onComplete = function()
    completions = completions + 1
  end

  -- A large host update with no presented draw reaches the full-black wait
  -- without completing, draining its source frames.
  state:update(5)

  Assert.isTrue(
    controller:view().phase ~= "complete",
    "an update without a presented black draw must stop at the full-black wait"
  )
  Assert.isNil(controller:result(), "the candidate stays unpublished without a presented draw")
  Assert.equal(completions, 0)

  -- Presenting the black frame unlocks exactly one handoff on the next
  -- update, which still preserves time it cannot drain.
  state:draw()
  state:update(5)

  Assert.equal(controller:view().phase, "complete")
  Assert.isTrue(state.accumulator > 0)
  Assert.equal(completions, 1)

  state:update(5)
  state:tick(5)
  Assert.equal(controller:view().phase, "complete")
  Assert.equal(completions, 1, "the handoff must stay a single event after completion")
end

-- Drawing must not alter the semantic state that a later host update drains.
-- Matching updates still produce matching semantics regardless of earlier
-- draw cadence, but only a presented full-black draw unlocks the handoff:
-- the undrawn path keeps waiting while the presented path completes.
function T.black_presentation_gates_completion_independent_of_prior_draw_cadence()
  local drawnState, drawnController = stateAtFreshFullArtHold(9, 4)
  local undrawnState, undrawnController = stateAtFreshFullArtHold(9, 4)
  local drawnCompletions = 0
  local undrawnCompletions = 0
  drawnState.onComplete = function()
    drawnCompletions = drawnCompletions + 1
  end
  undrawnState.onComplete = function()
    undrawnCompletions = undrawnCompletions + 1
  end

  local initial = semanticSnapshot(drawnController)
  Assert.deepEqual(initial, semanticSnapshot(undrawnController))
  drawnState:draw()
  Assert.deepEqual(semanticSnapshot(drawnController), initial, "drawing must not advance the controller source clock")

  for _, dt in ipairs({ 1, 43 / 30 }) do
    drawnState:update(dt)
    undrawnState:update(dt)
    Assert.deepEqual(
      semanticSnapshot(drawnController),
      semanticSnapshot(undrawnController),
      "matching host updates must produce matching semantics regardless of draw cadence"
    )
  end

  Assert.isTrue(drawnController:view().phase ~= "complete", "both paths must wait at full black")
  Assert.isTrue(undrawnController:view().phase ~= "complete", "both paths must wait at full black")
  Assert.equal(drawnCompletions, 0)
  Assert.equal(undrawnCompletions, 0)

  -- Presenting the black frame on only the drawn path unlocks only that path.
  drawnState:draw()
  Assert.equal(drawnCompletions, 0, "drawing must not itself complete the handoff")
  drawnState:update(1 / 30)
  undrawnState:update(1 / 30)
  Assert.equal(drawnController:view().phase, "complete")
  Assert.equal(drawnCompletions, 1)
  Assert.isTrue(undrawnController:view().phase ~= "complete", "no presented draw means no completion")
  Assert.equal(undrawnCompletions, 0)

  undrawnState:draw()
  undrawnState:update(1 / 30)
  Assert.equal(undrawnController:view().phase, "complete")
  Assert.equal(undrawnCompletions, 1)
end

function T.dialogue_completion_edge_does_not_enter_the_new_choice()
  local state, controller = stateHarness()
  local modal = true
  local completion
  controller.phase = "gender_confirm"
  controller.view = function(self)
    return {
      phase = self.phase,
      messageKey = modal and "profile.gender_confirm.male" or nil,
      message = modal and { tokens = {} } or nil,
      confirmationChoice = not modal and { kind = "gender", selected = 0 } or nil,
      genderCompositionProgress = 1,
      name = "",
      nameInputEnabled = false,
      genderFocus = 0,
      visual = "background",
    }
  end
  controller.messageCompleted = function(_, key)
    Assert.equal(key, "profile.gender_confirm.male")
    modal = false
    return true
  end
  local dialogue = {
    open = function()
      return {
        onComplete = function(_, callback)
          completion = callback
        end,
      }
    end,
    step = function()
      if completion then
        local callback = completion
        completion = nil
        modal = false
        callback()
      end
    end,
    isModal = function()
      return modal
    end,
    status = function()
      return {}
    end,
  }
  state.dialogueController = dialogue
  state:_sync()
  state:keypressed("return")
  Assert.deepEqual(controller.pressed, {})
  Assert.notNil(state:view().confirmationChoice)
end

function T.frozen_is_not_activated_while_still_waiting_close_without_action()
  local state, controller = stateHarness()
  local modal = true
  controller.phase = "name_confirm"
  controller.view = function(self)
    return {
      phase = self.phase,
      messageKey = "profile.name_confirm.male",
      message = { tokens = {} },
      confirmationChoice = nil,
      genderCompositionProgress = 1,
      nameCompositionProgress = 1,
      name = "GOLD",
      nameInputEnabled = false,
      genderFocus = 0,
      visual = "oak",
      primaryWidget = "oak",
      oakBgScrollX = 0,
    }
  end
  local dialogue = {
    stepCount = 0,
    isModal = function()
      return modal
    end,
    status = function()
      return {
        state = "WAITING_CLOSE",
        waiting = true,
        cursorPhase = 1,
        frameIndex = 0,
        visibleLines = { { { kind = "glyph", text = "Q" } } },
        scrollLines = nil,
        scrollOffsetY = 0,
        lineHeight = 16,
        lineSpacing = 0,
      }
    end,
    step = function(self)
      self.stepCount = self.stepCount + 1
    end,
    open = function()
      return { onComplete = function() end }
    end,
  }
  local renderer = {
    drawn = {},
    draw = function(self, c, _)
      self.drawn[#self.drawn + 1] = c
    end,
  }
  state.dialogueController = dialogue
  state.dialogueRenderer = renderer
  state.dialogueFormatter = {
    format = function()
      return { tokens = {}, text = "x", hadUnresolvedSubstitutions = false }
    end,
    choiceLabels = function()
      return { [0] = "YES", [1] = "NO" }
    end,
  }
  state.dialogueMessageKey = "profile.name_confirm.male"
  state:tick(1)
  Assert.isTrue(dialogue:isModal())
  state:draw()
  Assert.equal(renderer.drawn[1], dialogue, "real controller must remain draw owner while WAITING_CLOSE")
end

function T.completed_name_question_stays_visible_through_real_close_sequence()
  local tokens = {
    { kind = "glyph", text = "HELLO", code = 1, raw = { 1 } },
    { kind = "focus_indicator", control = 0x0200, name = "YESNO", args = { 0 } },
  }
  local pages = { { lines = { { tokens = tokens, width = 0 } }, breakKind = "eos" } }
  local cursor = { cycle = { 0, 1, 2, 1 }, framePrinterTicks = 9, placement = DIALOGUE_CURSOR_PLACEMENT }
  local dialogue = FieldDialogueController.new({
    layout = function()
      return {
        pages = pages,
        warnings = {},
        lineHeight = 16,
        lineSpacing = 2,
        textOriginX = 0,
        textOriginY = 0,
        contentWidth = 216,
        syntheticBreaks = 0,
      }
    end,
    policy = { interGlyphDelay = 1, glyphBudget = 2, abAcceleration = true },
    continueCursor = cursor,
  })
  local modal = true
  local resolved = false
  local semantic = fakeController()
  semantic.phase = "name_confirm"
  semantic.compositionProgress = 1
  semantic.choice = nil
  semantic.view = function(self)
    return {
      phase = self.phase,
      messageKey = modal and "profile.name_confirm.male" or nil,
      message = modal and { tokens = tokens } or nil,
      confirmationChoice = (not modal and not resolved) and { kind = "name", selected = 0 } or nil,
      genderCompositionProgress = self.compositionProgress,
      nameCompositionProgress = 1,
      name = "GOLD",
      nameInputEnabled = false,
      genderFocus = 0,
      visual = "oak",
      primaryWidget = "oak",
      oakBgScrollX = 0,
    }
  end
  semantic.messageCompleted = function(_, key)
    Assert.equal(key, "profile.name_confirm.male")
    modal = false
    return true
  end
  local renderer = {
    draws = {},
    draw = function(self, controllerArg, presentation)
      self.draws[#self.draws + 1] = {
        controller = controllerArg,
        presentation = presentation,
        status = controllerArg:status(),
      }
    end,
  }
  local state = OakIntroState.new({
    controller = semantic --[[@as OakIntroController]],
    manifest = INTRO_MANIFEST,
    textRenderer = {},
    choiceText = { release = function() end },
    renderer = {
      draw = function(_, _, overlay)
        if overlay then
          overlay()
        end
      end,
      dispose = function() end,
    },
    textInputHost = { setTextInput = function() end },
    dialogueController = dialogue,
    dialogueRenderer = renderer,
    dialogueFormatter = {
      format = function(_, _)
        return { tokens = tokens, text = "profile.name_confirm.male", hadUnresolvedSubstitutions = false }
      end,
      choiceLabels = function()
        return { [0] = "YES", [1] = "NO" }
      end,
    },
    glyphs = { "A" },
    width = 640,
    height = 480,
    dialogueCursorPlacement = DIALOGUE_CURSOR_PLACEMENT,
  })
  -- drive reveal until WAITING_CLOSE
  for _ = 1, 20 do
    if dialogue:status().state == "WAITING_CLOSE" then
      break
    end
    state:tick(1)
  end
  Assert.equal(dialogue:status().state, "WAITING_CLOSE", "real dialogue must reach WAITING_CLOSE")
  Assert.isTrue(dialogue:isModal())
  renderer.draws = {}
  state:draw()
  Assert.equal(#renderer.draws, 1, "while WAITING_CLOSE the real controller must own drawing")
  Assert.equal(renderer.draws[1].controller, dialogue)
  Assert.isTrue(renderer.draws[1].controller:isModal())
  -- press confirm to move WAITING_CLOSE -> CLOSING; close edge must not select YES yet
  renderer.draws = {}
  state:keypressed("return")
  Assert.equal(dialogue:status().state, "CLOSING", "confirm edge must move to CLOSING")
  Assert.isTrue(dialogue:isModal(), "CLOSING is still modal and real controller owns drawing")
  Assert.isNil(semantic.choice, "close edge must not activate YES")
  Assert.isTrue(modal, "semantic choice must not be active while CLOSING")
  state:draw()
  Assert.equal(#renderer.draws, 1, "while CLOSING real controller still draws")
  Assert.equal(renderer.draws[1].controller, dialogue)
  -- next source tick closes and publishes frozen question
  renderer.draws = {}
  state:tick(1)
  Assert.equal(dialogue:status().state, "CLOSED", "next tick must close the real controller")
  Assert.isFalse(dialogue:isModal())
  Assert.deepEqual(
    semantic:view().confirmationChoice,
    { kind = "name", selected = 0 },
    "name choice must be active after close"
  )
  Assert.equal(modal, false)
  state:draw()
  Assert.equal(#renderer.draws, 1, "after close the frozen question must still be drawn")
  local drawn = renderer.draws[1]
  Assert.isTrue(drawn.controller ~= dialogue, "frozen adapter must be a different object")
  Assert.isTrue(drawn.controller:isModal(), "frozen adapter must appear modal")
  local status = drawn.status
  Assert.equal(status.waiting, false, "frozen must not show continuation cursor")
  Assert.isNil(status.cursorPhase, "frozen must have no cursor phase")
  Assert.isNil(status.scrollLines)
  Assert.equal(status.scrollOffsetY, 0)
  Assert.equal(status.lineHeight, 16)
  Assert.equal(status.lineSpacing, 2)
  Assert.equal(status.frameIndex, 0)
  Assert.equal(#status.visibleLines, 1)
  Assert.equal(status.visibleLines[1][1].text, "HELLO")
  Assert.equal(status.visibleLines[1][2].kind, "focus_indicator")
  Assert.notNil(drawn.presentation)
  -- resolving choice must stop drawing the old frozen question
  renderer.draws = {}
  semantic:press("yes")
  resolved = true
  semantic.phase = "final_dialogue"
  state:_sync()
  state:draw()
  -- after YES the old frozen question must not be drawn; real dialogue for final takes over (or nothing if not opened yet in this harness)
  -- the key is frozen is no longer the draw source
  local stillFrozen = false
  for _, entry in ipairs(renderer.draws) do
    if entry.status.visibleLines[1] and entry.status.visibleLines[1][1].text == "HELLO" then
      stillFrozen = true
    end
  end
  Assert.isFalse(stillFrozen, "old frozen question must not be drawn after resolving choice")
end

function T.gender_question_stays_visible_through_selection_and_confirmation()
  local helloTokens = { { kind = "glyph", text = "HELLO", code = 1, raw = { 1 } } }
  local byeTokens = { { kind = "glyph", text = "BYE", code = 2, raw = { 2 } } }
  local cursor = { cycle = { 0, 1, 2, 1 }, framePrinterTicks = 9, placement = DIALOGUE_CURSOR_PLACEMENT }
  local dialogue = FieldDialogueController.new({
    layout = function(message)
      return {
        pages = { { lines = { { tokens = message.tokens, width = 0 } }, breakKind = "eos" } },
        warnings = {},
        lineHeight = 16,
        lineSpacing = 2,
        textOriginX = 0,
        textOriginY = 0,
        contentWidth = 216,
        syntheticBreaks = 0,
      }
    end,
    policy = { interGlyphDelay = 1, glyphBudget = 2, abAcceleration = true },
    continueCursor = cursor,
  })
  local liveKey = "profile.gender_question"
  local liveActive = true
  local choiceActive = false
  local semantic = fakeController()
  semantic.phase = "gender_question"
  semantic.compositionProgress = 0
  semantic.view = function(self)
    local tokens = liveKey == "profile.gender_question" and helloTokens or byeTokens
    return {
      phase = self.phase,
      messageKey = liveActive and liveKey or nil,
      message = liveActive and { tokens = tokens } or nil,
      confirmationChoice = choiceActive and { kind = "gender", selected = 0 } or nil,
      genderCompositionProgress = self.compositionProgress,
      nameCompositionProgress = 0,
      name = "",
      nameInputEnabled = false,
      genderFocus = 0,
      visual = "background",
    }
  end
  semantic.messageCompleted = function(_, key)
    Assert.equal(key, liveKey)
    liveActive = false
    if liveKey == "profile.gender_question" then
      semantic.phase = "gender_select"
      semantic.compositionProgress = 1
    else
      choiceActive = true
    end
    return true
  end
  local renderer = {
    draws = {},
    draw = function(self, controllerArg, presentation)
      self.draws[#self.draws + 1] = {
        controller = controllerArg,
        presentation = presentation,
        status = controllerArg:status(),
      }
    end,
  }
  local tokensByKey = {
    ["profile.gender_question"] = helloTokens,
    ["profile.gender_confirm.male"] = byeTokens,
  }
  local state = OakIntroState.new({
    controller = semantic --[[@as OakIntroController]],
    manifest = INTRO_MANIFEST,
    textRenderer = {},
    choiceText = { release = function() end },
    renderer = {
      draw = function(_, _, overlay)
        if overlay then
          overlay()
        end
      end,
      dispose = function() end,
    },
    textInputHost = { setTextInput = function() end },
    dialogueController = dialogue,
    dialogueRenderer = renderer,
    dialogueFormatter = {
      format = function(_, key)
        return { tokens = assert(tokensByKey[key]), text = key, hadUnresolvedSubstitutions = false }
      end,
      choiceLabels = function()
        return { [0] = "YES", [1] = "NO" }
      end,
    },
    glyphs = { "A" },
    width = 640,
    height = 480,
    dialogueCursorPlacement = DIALOGUE_CURSOR_PLACEMENT,
  })
  local function driveToWait()
    for _ = 1, 20 do
      if dialogue:status().state == "WAITING_CLOSE" then
        break
      end
      state:tick(1)
    end
    Assert.equal(dialogue:status().state, "WAITING_CLOSE")
  end
  local function frozenDraw()
    renderer.draws = {}
    state:draw()
    Assert.equal(#renderer.draws, 1, "held question must be drawn")
    return renderer.draws[1]
  end
  driveToWait()
  renderer.draws = {}
  state:draw()
  Assert.equal(#renderer.draws, 1, "live question owns drawing while waiting")
  Assert.equal(renderer.draws[1].controller, dialogue)
  state:keypressed("return")
  Assert.equal(dialogue:status().state, "CLOSING")
  state:tick(1)
  Assert.equal(dialogue:status().state, "CLOSED")
  Assert.isFalse(dialogue:isModal())
  Assert.equal(semantic.phase, "gender_select")
  local held = frozenDraw()
  Assert.isTrue(held.controller ~= dialogue, "held snapshot must be presentation-only")
  Assert.equal(held.status.waiting, false, "held dialogue never carries the continuation cursor")
  Assert.isNil(held.status.cursorPhase)
  Assert.isNil(held.status.scrollLines)
  Assert.equal(held.status.scrollOffsetY, 0)
  Assert.equal(held.status.visibleLines[1][1].text, "HELLO")
  Assert.notNil(held.presentation)
  semantic.phase = "gender_select"
  semantic.compositionProgress = 1
  state:_sync()
  local throughSelect = frozenDraw()
  Assert.equal(throughSelect.status.visibleLines[1][1].text, "HELLO", "question remains through gender_select")
  Assert.isNil(throughSelect.status.cursorPhase)
  liveKey = "profile.gender_confirm.male"
  liveActive = true
  semantic.phase = "gender_confirm"
  state:_sync()
  Assert.isNil(state._frozenStatus, "opening the confirm message replaces the old held question")
  driveToWait()
  renderer.draws = {}
  state:draw()
  Assert.equal(renderer.draws[1].controller, dialogue, "live confirm owns drawing while waiting")
  Assert.equal(renderer.draws[1].status.visibleLines[1][1].text, "BYE")
  state:keypressed("return")
  state:tick(1)
  Assert.equal(dialogue:status().state, "CLOSED")
  Assert.deepEqual(semantic:view().confirmationChoice, { kind = "gender", selected = 0 })
  local heldConfirm = frozenDraw()
  Assert.equal(heldConfirm.status.visibleLines[1][1].text, "BYE", "confirm question held while YES/NO active")
  Assert.equal(heldConfirm.status.waiting, false)
  Assert.isNil(heldConfirm.status.cursorPhase)
  renderer.draws = {}
  choiceActive = false
  semantic.phase = "name_prompt"
  state:_sync()
  state:draw()
  local stillHeld = false
  for _, entry in ipairs(renderer.draws) do
    if entry.status.visibleLines[1] and entry.status.visibleLines[1][1].text == "BYE" then
      stillHeld = true
    end
  end
  Assert.isFalse(stillHeld, "choosing YES/NO clears the hold")
end

function T.repeated_gender_question_stays_visible_through_selection()
  local helloTokens = { { kind = "glyph", text = "HELLO", code = 1, raw = { 1 } } }
  local cursor = { cycle = { 0, 1, 2, 1 }, framePrinterTicks = 9, placement = DIALOGUE_CURSOR_PLACEMENT }
  local dialogue = FieldDialogueController.new({
    layout = function(message)
      return {
        pages = { { lines = { { tokens = message.tokens, width = 0 } }, breakKind = "eos" } },
        warnings = {},
        lineHeight = 16,
        lineSpacing = 2,
        textOriginX = 0,
        textOriginY = 0,
        contentWidth = 216,
        syntheticBreaks = 0,
      }
    end,
    policy = { interGlyphDelay = 1, glyphBudget = 2, abAcceleration = true },
    continueCursor = cursor,
  })
  local liveActive = true
  local nameProgress = 1
  local semantic = fakeController()
  semantic.phase = "gender_question"
  semantic.view = function(self)
    return {
      phase = self.phase,
      messageKey = liveActive and "profile.gender_question" or nil,
      message = liveActive and { tokens = helloTokens } or nil,
      confirmationChoice = nil,
      genderCompositionProgress = 1,
      nameCompositionProgress = nameProgress,
      name = "GOLD",
      nameInputEnabled = false,
      genderFocus = 0,
      visual = "background",
    }
  end
  semantic.messageCompleted = function(_, key)
    Assert.equal(key, "profile.gender_question")
    liveActive = false
    semantic.phase = "gender_select"
    nameProgress = 0
    return true
  end
  local renderer = {
    draws = {},
    draw = function(self, controllerArg, presentation)
      self.draws[#self.draws + 1] = {
        controller = controllerArg,
        presentation = presentation,
        status = controllerArg:status(),
      }
    end,
  }
  local state = OakIntroState.new({
    controller = semantic --[[@as OakIntroController]],
    manifest = INTRO_MANIFEST,
    textRenderer = {},
    choiceText = { release = function() end },
    renderer = {
      draw = function(_, _, overlay)
        if overlay then
          overlay()
        end
      end,
      dispose = function() end,
    },
    textInputHost = { setTextInput = function() end },
    dialogueController = dialogue,
    dialogueRenderer = renderer,
    dialogueFormatter = {
      format = function(_, _)
        return { tokens = helloTokens, text = "profile.gender_question", hadUnresolvedSubstitutions = false }
      end,
      choiceLabels = function()
        return { [0] = "YES", [1] = "NO" }
      end,
    },
    glyphs = { "A" },
    width = 640,
    height = 480,
    dialogueCursorPlacement = DIALOGUE_CURSOR_PLACEMENT,
  })
  for _ = 1, 20 do
    if dialogue:status().state == "WAITING_CLOSE" then
      break
    end
    state:tick(1)
  end
  Assert.equal(dialogue:status().state, "WAITING_CLOSE")
  state:keypressed("return")
  Assert.equal(dialogue:status().state, "CLOSING")
  state:tick(1)
  Assert.equal(dialogue:status().state, "CLOSED")
  Assert.equal(semantic.phase, "gender_select")
  Assert.equal(nameProgress, 0)
  renderer.draws = {}
  state:draw()
  Assert.equal(#renderer.draws, 1, "the repeated question must still be drawn while choosing")
  local held = renderer.draws[1]
  Assert.isTrue(held.controller ~= dialogue, "the held snapshot must be presentation-only")
  Assert.equal(held.status.waiting, false, "the held question never carries the continuation cursor")
  Assert.isNil(held.status.cursorPhase)
  Assert.equal(held.status.visibleLines[1][1].text, "HELLO")
end

return { tests = T }
