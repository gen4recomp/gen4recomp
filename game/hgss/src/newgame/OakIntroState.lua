-- Top-level Oak/profile presentation state. It maps host callbacks to one
-- semantic controller, owns text-input mode and intro images, and hands one
-- finalized unpublished candidate to its caller.

local OakIntroLayout = require("game.hgss.src.newgame.OakIntroLayout")
local OakIntroRenderer = require("game.hgss.src.newgame.OakIntroRenderer")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local DialoguePresentationLayout = require("libs.hgss.src.ui.DialoguePresentationLayout")

---@class OakIntroStateController: OakIntroController
---@field start fun(self: OakIntroStateController): boolean
---@field tick fun(self: OakIntroStateController, frames: integer)
---@field confirmHandoffPresented fun(self: OakIntroStateController): boolean
---@field view fun(self: OakIntroStateController): OakIntroControllerView
---@field result fun(self: OakIntroStateController): table<string, unknown>?
---@field press fun(self: OakIntroStateController, action: string): boolean
---@field deleteGlyph fun(self: OakIntroStateController): boolean
---@field inputText fun(self: OakIntroStateController, text: string): boolean
---@field messageCompleted fun(self: OakIntroStateController, key: string): boolean
---@field dispose fun(self: OakIntroStateController)

---@class OakIntroStateRenderer
---@field draw fun(self: OakIntroStateRenderer, view: OakIntroStateView)
---@field dispose fun(self: OakIntroStateRenderer)

---@class OakIntroStateTextInputHost
---@field setTextInput fun(self: OakIntroStateTextInputHost, enabled: boolean)

---@class OakIntroStateAudioSink
---@field update? fun(self: OakIntroStateAudioSink)

---@class OakIntroStateRectangle
---@field x number
---@field y number
---@field width number
---@field height number

---@class OakIntroStateSubjectRectangle: OakIntroStateRectangle
---@field scale number

---@class OakIntroStateLayout
---@field viewport OakIntroStateRectangle
---@field message OakIntroStateRectangle
---@field nameGrid table<integer, { rect: OakIntroStateRectangle, kind: string, glyph: string? }>
---@field nameKeys table<integer, { rect: OakIntroStateRectangle, kind: string, glyph: string?, label: string? }>
---@field namePreview OakIntroStateRectangle?
---@field stageContent OakIntroStateRectangle
---@field dialogue { outerRect: OakIntroStateRectangle, scale: number }?
---@field sourceCanvas { scale: number, origin: { x: number, y: number } }?
---@field revealCanvas { scale: number, origin: { x: number, y: number } }?
---@field reveal OakIntroStateSubjectRectangle?
---@field stage OakIntroStateRectangle
---@field genderButtons table<string, unknown>?
---@field confirmationButtons table<string, unknown>?
---@field selectedProfileButton table<string, unknown>?
---@field virtualKeyColumns integer?
---@field genderFocus integer
---@field subject OakIntroStateSubjectRectangle?
---@field safeFrame OakIntroStateRectangle
---@field scene OakIntroStateRectangle
---@field oakRegion OakIntroStateRectangle?
---@field selectorRegion OakIntroStateRectangle?

---@class OakIntroStateView: OakIntroControllerView
---@field phase string
---@field message string|table<string, unknown>|nil
---@field messageKey string?
---@field dialogueStatus table<string, unknown>?
---@field dialoguePresentation DialoguePresentationLayout.Presentation?
---@field dialogue table<string, unknown>?
---@field visual string
---@field genderFocus integer
---@field name string
---@field nameInputEnabled boolean
---@field choiceLabels table<integer, string>?
---@field layout OakIntroStateLayout?

---@class OakIntroStateLayoutView: OakIntroStateView
---@field layout OakIntroStateLayout

---@class OakIntroStateOptions
---@field controller OakIntroController
---@field manifest table<string, unknown>
---@field renderer OakIntroStateRenderer?
---@field graphics unknown?
---@field imageLoader (fun(path: string): unknown)?
---@field textInputHost OakIntroStateTextInputHost?
---@field glyphs string[]?
---@field width number?
---@field height number?
---@field onComplete fun(result: table<string, unknown>)?
---@field audioSink OakIntroStateAudioSink?
---@field audioLifetime table<string, unknown>?
---@field textRenderer table<string, unknown>
---@field choiceText table<string, unknown>
---@field dialogueController table<string, unknown>?
---@field dialogueRenderer table<string, unknown>?
---@field dialogueText table<string, unknown>?
---@field dialogueMessages table<string, unknown>?
---@field dialogueFormatter table<string, unknown>?
---@field dialogueMessageKey string?
---@field dialogueCursorPlacement { x: number, y: number, width: number, height: number }?

---@class OakIntroState
---@field new fun(options: OakIntroStateOptions): OakIntroState
---@field controller OakIntroStateController
---@field renderer OakIntroStateRenderer
---@field inputHost OakIntroStateTextInputHost
---@field glyphs string[]
---@field width number
---@field height number
---@field accumulator number
---@field textInputEnabled boolean?
---@field completed boolean
---@field onComplete fun(result: table<string, unknown>)?
---@field audioSink OakIntroStateAudioSink?
---@field audioLifetime table<string, unknown>?
---@field manifest table<string, unknown>
---@field dialogueController table<string, unknown>?
---@field dialogueRenderer table<string, unknown>?
---@field dialogueMessages table<string, unknown>?
---@field dialogueFormatter table<string, unknown>?
---@field choiceLabels table<integer, string>?
---@field dialogueText table<string, unknown>?
---@field choiceText table<string, unknown>
---@field dialoguePresentation DialoguePresentationLayout.Presentation?
---@field dialogueCursorPlacement { x: number, y: number, width: number, height: number }?
---@field disposed boolean
---@field _blackHandoffPresented boolean
---@field _frozenStatus table<string, unknown>?
---@field _frozenAdapter table<string, unknown>?
---@field _setTextInput fun(self: OakIntroState, enabled: boolean)
---@field _acknowledgePresentedHandoff fun(self: OakIntroState)
---@field _clearFrozen fun(self: OakIntroState)
---@field _stepDialogue fun(self: OakIntroState, snapshot: table<string, unknown>?): table<string, unknown>?
---@field _sync fun(self: OakIntroState): OakIntroStateView
---@field update fun(self: OakIntroState, dt: number)
---@field tick fun(self: OakIntroState, frames: integer)
---@field view fun(self: OakIntroState): OakIntroStateLayoutView
---@field draw fun(self: OakIntroState)
---@field resize fun(self: OakIntroState, width: number, height: number)
---@field keypressed fun(self: OakIntroState, key: string, scancode: string?, isrepeat: boolean?)
---@field press fun(self: OakIntroState, action: string): boolean
---@field textinput fun(self: OakIntroState, text: string)
---@field gamepadpressed fun(self: OakIntroState, joystick: unknown, button: string)
---@field _pointer fun(self: OakIntroState, x: number, y: number)
---@field mousepressed fun(self: OakIntroState, x: number, y: number, button: integer)
---@field touchpressed fun(self: OakIntroState, id: unknown, x: number, y: number)
---@field dispose fun(self: OakIntroState)
local OakIntroState = {}
OakIntroState.__index = OakIntroState

-- Float slack keeps an exact source-frame boundary from losing a source tick.
local SOURCE_FRAME_HZ = 30
local SOURCE_FRAME_DURATION = 1 / SOURCE_FRAME_HZ
local SOURCE_FRAME_EPSILON = 1e-14

local DEFAULT_GLYPHS = {
  "A",
  "B",
  "C",
  "D",
  "E",
  "F",
  "G",
  "H",
  "I",
  "J",
  "K",
  "L",
  "M",
  "N",
  "O",
  "P",
  "Q",
  "R",
  "S",
  "T",
  "U",
  "V",
  "W",
  "X",
  "Y",
  "Z",
}

local function glyphList(value)
  local result = {}
  for _, glyph in ipairs(value or DEFAULT_GLYPHS) do
    assert(type(glyph) == "string", "Oak virtual keyboard glyphs must be strings")
    local count = 0
    for _ in Utf8Glyphs.iter(glyph) do
      count = count + 1
    end
    assert(count == 1, "Oak virtual keyboard entries must be one UTF-8 glyph")
    result[#result + 1] = glyph
  end
  return result
end

local function textInputHost(host)
  if host ~= nil then
    assert(type(host.setTextInput) == "function", "Oak text-input host must provide setTextInput")
    return host
  end
  local function setTextInput(_, enabled)
    love.keyboard.setTextInput(enabled)
  end
  return {
    setTextInput = setTextInput,
  }
end

---@param status table<string, unknown>
---@return table<string, unknown>
local function copyFrozenStatus(status)
  assert(type(status) == "table", "dialogue status is required for frozen presentation")
  local frozen = {}
  frozen.frameIndex = status.frameIndex
  frozen.lineHeight = assert(status.lineHeight, "dialogue lineHeight is required")
  frozen.lineSpacing = assert(status.lineSpacing, "dialogue lineSpacing is required")
  frozen.waiting = false
  frozen.cursorPhase = nil
  frozen.scrollLines = nil
  frozen.scrollOffsetY = 0
  local lines = {}
  for index, line in ipairs(status.visibleLines or {}) do
    local src = line.tokens or line
    local copy = {}
    for tokenIndex, token in ipairs(src) do
      copy[tokenIndex] = token
    end
    lines[index] = copy
  end
  frozen.visibleLines = lines
  return frozen
end

-- Presentation-only retention for completed Oak questions: the gender
-- question stays through composition/selection, and gender/name
-- confirmations stay while their YES/NO choice is active. Greeting and
-- exposition dialogue never sticks.
---@param view table<string, unknown>
---@return boolean
local function retainsCompletedQuestion(view)
  if view.phase == "gender_composition_transition" or view.phase == "gender_select" then
    return true
  end
  local choice = view.confirmationChoice
  return choice ~= nil and (choice.kind == "gender" or choice.kind == "name")
end

---@param options OakIntroStateOptions
---@return OakIntroState
function OakIntroState.new(options)
  assert(type(options) == "table" and options.controller, "Oak state requires a controller")
  assert(type(options.manifest) == "table", "Oak state requires generated intro assets")
  assert(options.textRenderer, "Oak state requires the shared FieldTextRenderer")
  assert(options.choiceText, "Oak state requires the font-4 FieldTextRenderer")
  if options.dialogueController then
    assert(options.dialogueFormatter, "Oak state requires its message formatter")
    assert(type(options.dialogueFormatter.format) == "function", "Oak message formatter is invalid")
  end
  local width, height = options.width, options.height
  if width == nil or height == nil then
    width, height = love.graphics.getDimensions()
  end
  local self
  local ok, result = pcall(function()
    local renderer = options.renderer
      or OakIntroRenderer.new({
        manifest = options.manifest,
        graphics = options.graphics,
        imageLoader = options.imageLoader,
        text = assert(options.textRenderer, "Oak state requires the shared FieldTextRenderer"),
        choiceText = assert(options.choiceText, "Oak state requires the font-4 FieldTextRenderer"),
      })
    self = setmetatable({
      controller = options.controller,
      manifest = options.manifest,
      renderer = renderer --[[@as OakIntroStateRenderer]],
      inputHost = textInputHost(options.textInputHost),
      glyphs = glyphList(options.glyphs),
      width = width,
      height = height,
      accumulator = 0,
      textInputEnabled = nil,
      completed = false,
      disposed = false,
      onComplete = options.onComplete,
      audioSink = options.audioSink,
      audioLifetime = options.audioLifetime,
      dialogueController = options.dialogueController,
      dialogueRenderer = options.dialogueRenderer,
      dialogueFormatter = options.dialogueFormatter,
      choiceLabels = options.dialogueFormatter and options.dialogueFormatter:choiceLabels() or nil,
      dialogueText = options.dialogueText,
      choiceText = options.choiceText,
      dialoguePresentation = nil,
      dialogueMessageKey = nil,
      dialogueCursorPlacement = options.dialogueCursorPlacement,
      _blackHandoffPresented = false,
      _frozenStatus = nil,
      _frozenAdapter = nil,
    }, OakIntroState)
    self:_setTextInput(false)
    self.controller:start()
    return self
  end)
  if not ok then
    if options.controller.dispose then
      pcall(options.controller.dispose, options.controller)
    end
    if self and self.renderer and self.renderer.dispose then
      pcall(self.renderer.dispose, self.renderer)
    end
    if self and self.audioLifetime then
      pcall(self.audioLifetime.dispose, self.audioLifetime)
    end
    error(result, 0)
  end
  return self
end

function OakIntroState:_setTextInput(enabled)
  if self.textInputEnabled == enabled then
    return
  end
  self.inputHost:setTextInput(enabled)
  self.textInputEnabled = enabled
end

function OakIntroState:_clearFrozen()
  self._frozenStatus = nil
  self._frozenAdapter = nil
end

-- Consumes a successfully presented full-black handoff frame, if any, by
-- acknowledging it to the controller. Only a later update may finalize the
-- handoff; drawing itself never completes it.
function OakIntroState:_acknowledgePresentedHandoff()
  if not self._blackHandoffPresented then
    return
  end
  self._blackHandoffPresented = false
  self.controller:confirmHandoffPresented()
end

function OakIntroState:_stepDialogue(snapshot)
  local dialogue = self.dialogueController
  if not dialogue then
    return nil
  end
  local candidate
  do
    local status = dialogue:status()
    if status.state == "CLOSING" then
      candidate = copyFrozenStatus(status)
    end
  end
  local result = dialogue:step(snapshot)
  if candidate and not dialogue:isModal() then
    local view = self.controller:view()
    if retainsCompletedQuestion(view) then
      local frozen = candidate
      self._frozenStatus = frozen
      local function frozenIsModal()
        return true
      end
      local function frozenStatus()
        return frozen
      end
      self._frozenAdapter = {
        isModal = frozenIsModal,
        status = frozenStatus,
      }
    end
  end
  return result
end

function OakIntroState:_sync()
  local view = self.controller:view()
  ---@cast view OakIntroStateView
  if self._frozenStatus and not retainsCompletedQuestion(view) then
    self:_clearFrozen()
  end
  if
    self._frozenStatus
    and self.dialogueController
    and view.messageKey ~= self.dialogueMessageKey
    and view.messageKey
  then
    self:_clearFrozen()
  end
  self:_setTextInput(view.nameInputEnabled)
  if self.dialogueController and view.messageKey ~= self.dialogueMessageKey then
    self.dialogueMessageKey = view.messageKey
    if view.messageKey then
      local message = self.dialogueFormatter:format(view.messageKey, { playerName = view.name })
      assert(not message.hadUnresolvedSubstitutions, "Oak message has unresolved substitutions")
      local handle = self.dialogueController:open({
        id = "oak:" .. view.messageKey,
        message = message,
        frameIndex = 0,
        allowCancel = false,
      })
      handle:onComplete(function()
        self.controller:messageCompleted(view.messageKey)
      end)
    end
  end
  if view.phase == "complete" and not self.completed then
    self.completed = true
    if self.onComplete then
      self.onComplete(assert(self.controller:result()))
    end
  end
  return view
end

function OakIntroState:update(dt)
  assert(type(dt) == "number" and dt >= 0, "Oak update dt must be non-negative")
  self:_acknowledgePresentedHandoff()
  self.accumulator = self.accumulator + dt
  while self.accumulator + SOURCE_FRAME_EPSILON >= SOURCE_FRAME_DURATION do
    self.accumulator = math.max(0, self.accumulator - SOURCE_FRAME_DURATION)
    local phaseBeforeDialogue = self.controller:view().phase
    if self.dialogueController then
      self:_stepDialogue()
    end
    local phaseAfterDialogue = self.controller:view().phase
    local compositionStarted = phaseBeforeDialogue == "gender_question"
      and (phaseAfterDialogue == "gender_composition_transition" or phaseAfterDialogue == "name_composition_return")
    if not compositionStarted then
      self.controller:tick(1)
    end
    if self.controller:view().phase == "complete" then
      break
    end
  end
  if self.audioSink and self.audioSink.update then
    self.audioSink:update()
  end
  self:_sync()
end

function OakIntroState:tick(frames)
  assert(frames >= 0 and frames % 1 == 0, "Oak tick count must be a non-negative integer")
  self:_acknowledgePresentedHandoff()
  for _ = 1, frames do
    local phaseBeforeDialogue = self.controller:view().phase
    if self.dialogueController then
      self:_stepDialogue()
    end
    local phaseAfterDialogue = self.controller:view().phase
    local compositionStarted = phaseBeforeDialogue == "gender_question"
      and (phaseAfterDialogue == "gender_composition_transition" or phaseAfterDialogue == "name_composition_return")
    if not compositionStarted then
      self.controller:tick(1)
    end
  end
  self:_sync()
end

function OakIntroState:view()
  local view = self.controller:view()
  ---@cast view OakIntroStateView
  view.layout = OakIntroLayout.compute(self.width, self.height, view, self.glyphs, self.manifest)
  if self.dialogueController then
    view.dialogueStatus = self.dialogueController:status()
    view.dialoguePresentation = view.layout.dialogue
        and DialoguePresentationLayout.compute(view.layout.dialogue.outerRect, {
          scale = view.layout.dialogue.scale,
          cursorPlacement = self.dialogueCursorPlacement,
        })
      or nil
  end
  view.choiceLabels = self.choiceLabels
  ---@cast view OakIntroStateLayoutView
  return view
end

function OakIntroState:draw()
  local view = self:view()
  self.renderer:draw(view)
  if self.dialogueController and self.dialogueRenderer then
    if self.dialogueController:isModal() then
      self.dialogueRenderer:draw(self.dialogueController, view.dialoguePresentation)
    elseif self._frozenAdapter and view.dialoguePresentation and retainsCompletedQuestion(view) then
      self.dialogueRenderer:draw(self._frozenAdapter, view.dialoguePresentation)
    end
  end
  -- Only a successful draw of the waiting full-black frame unlocks the
  -- handoff; a failed draw raises above and records nothing. Completion
  -- itself happens on a later update, never here.
  if view.phase == "handoff_black" and view.finalFadeAlpha >= 1 then
    self._blackHandoffPresented = true
  end
end

function OakIntroState:resize(width, height)
  assert(type(width) == "number" and type(height) == "number", "Oak resize needs dimensions")
  self.width, self.height = width, height
end

local CONFIRM_KEYS = { ["return"] = true, kpenter = true, space = true }

---@param key string
---@param isrepeat boolean?
function OakIntroState:keypressed(key, _, isrepeat)
  if isrepeat and CONFIRM_KEYS[key] then
    return
  end
  if key == "left" or key == "right" or key == "up" or key == "down" or CONFIRM_KEYS[key] or key == "escape" then
    local action = key == "escape" and "cancel"
      or ({ ["left"] = "left", ["right"] = "right", ["up"] = "up", ["down"] = "down" })[key]
      or "confirm"
    if self.dialogueController and self.dialogueController:isModal() then
      self:_stepDialogue({ actionPressed = action == "confirm", cancelPressed = action == "cancel" })
      self:_sync()
      return
    end
    self.controller:press(action)
  elseif key == "backspace" then
    self.controller:deleteGlyph()
  end
  self:_sync()
end

function OakIntroState:textinput(text)
  self.controller:inputText(text)
  self:_sync()
end

function OakIntroState:gamepadpressed(_, button)
  local action = ({ dpup = "up", dpdown = "down", dpleft = "left", dpright = "right", a = "confirm", b = "cancel" })[button]
  if
    action == "left"
    or action == "right"
    or action == "up"
    or action == "down"
    or action == "confirm"
    or action == "cancel"
  then
    if self.dialogueController and self.dialogueController:isModal() then
      self:_stepDialogue({ actionPressed = action == "confirm", cancelPressed = action == "cancel" })
      self:_sync()
      return
    end
    self.controller:press(action)
  end
  self:_sync()
end

function OakIntroState:_pointer(x, y)
  local view = self:view()
  local layout = view.layout
  if self.dialogueController and self.dialogueController:isModal() then
    self:_sync()
    return
  elseif layout.confirmationButtons then
    for choice = 0, 1 do
      local entry = layout.confirmationButtons[choice]
      if entry and OakIntroLayout.contains(entry.rect, x, y) then
        self.controller:press(entry.key)
        self:_sync()
        return
      end
    end
  elseif layout.genderButtons then
    for gender = 0, 1 do
      local entry = layout.genderButtons[gender]
      if entry and OakIntroLayout.contains(entry.rect, x, y) then
        self.controller:press(entry.key)
        self:_sync()
        return
      end
    end
  elseif view.phase == "name_edit" then
    for _, entry in pairs(layout.nameKeys or layout.nameGrid) do
      if OakIntroLayout.contains(entry.rect, x, y) then
        if entry.kind == "glyph" then
          self.controller:inputText(assert(entry.glyph))
        elseif entry.kind == "delete" then
          self.controller:deleteGlyph()
        elseif entry.kind == "confirm" then
          self.controller:press("submit")
        end
        return
      end
    end
  end
  self:_sync()
end

function OakIntroState:mousepressed(x, y, button)
  if button == 1 then
    self:_pointer(x, y)
  end
end

function OakIntroState:touchpressed(_, x, y)
  self:_pointer(x, y)
end

function OakIntroState:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self:_clearFrozen()
  self:_setTextInput(false)
  self.controller:dispose()
  if self.renderer then
    self.renderer:dispose()
    self.renderer = nil
  end
  if self.audioLifetime then
    self.audioLifetime:dispose()
    self.audioLifetime = nil
  end
  if self.dialogueRenderer and self.dialogueRenderer.release then
    self.dialogueRenderer:release()
  end
  if self.dialogueText and self.dialogueText.release then
    self.dialogueText:release()
  end
  if self.choiceText and self.choiceText.release then
    self.choiceText:release()
  end
  if self.dialogueController and self.dialogueController.dispose then
    self.dialogueController:dispose()
  end
end

return OakIntroState
