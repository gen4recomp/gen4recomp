-- Top-level Oak/profile presentation state. It maps host callbacks to one
-- semantic controller, owns text-input mode and intro images, and hands one
-- finalized unpublished candidate to its caller.

local HgssInputBindings = require("game.hgss.src.HgssInputBindings")
local ApplicationPresentation = require("game.hgss.src.ui.ApplicationPresentation")
local DisplayContext = require("game.hgss.src.ui.DisplayContext")
local NamingInterface = require("game.hgss.src.newgame.NamingInterface")
local OakIntroLayout = require("game.hgss.src.newgame.OakIntroLayout")
local OakIntroRenderer = require("game.hgss.src.newgame.OakIntroRenderer")
local PixelScale = require("libs.ui.src.PixelScale")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local DialoguePresentationLayout = require("libs.hgss.src.ui.DialoguePresentationLayout")

---@class OakIntroStateController: OakIntroController
---@field start fun(self: OakIntroStateController): boolean
---@field tick fun(self: OakIntroStateController, frames: integer)
---@field confirmHandoffPresented fun(self: OakIntroStateController): boolean
---@field view fun(self: OakIntroStateController): OakIntroControllerView
---@field result fun(self: OakIntroStateController): table<string, unknown>?
---@field press fun(self: OakIntroStateController, action: string): boolean
---@field activateNameCell fun(self: OakIntroStateController, row: integer, column: integer): boolean
---@field activateNameControl fun(self: OakIntroStateController, id: string): boolean
---@field deleteGlyph fun(self: OakIntroStateController): boolean
---@field inputText fun(self: OakIntroStateController, text: string): boolean
---@field messageCompleted fun(self: OakIntroStateController, key: string): boolean
---@field dispose fun(self: OakIntroStateController)

---@class OakIntroStateRenderer
---@field draw fun(self: OakIntroStateRenderer, view: OakIntroStateView, overlay: (fun())?)
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
---@field namingScreen table<string, unknown>?
---@field stageContent OakIntroStateRectangle
---@field dialogue { outerRect: OakIntroStateRectangle, scale: number }?
---@field sourceCanvas { scale: number, origin: { x: number, y: number } }?
---@field revealCanvas { scale: number, origin: { x: number, y: number } }?
---@field reveal OakIntroStateSubjectRectangle?
---@field stage OakIntroStateRectangle
---@field genderButtons table<integer, OakGenderCardEntry>?
---@field confirmationButtons table<string, unknown>?
---@field selectedProfileButton OakGenderCardEntry?
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
---@field pixelSurface PixelScale.Surface?
---@field namingPresentation table<string, unknown>?

---@class OakIntroStateLayoutView: OakIntroStateView
---@field layout OakIntroStateLayout

---@class OakIntroStateOptions
---@field controller OakIntroController
---@field manifest table<string, unknown>
---@field renderer OakIntroStateRenderer?
---@field graphics unknown?
---@field imageLoader (fun(path: string): unknown)?
---@field uiManifest table<string, unknown>?
---@field textInputHost OakIntroStateTextInputHost?
---@field glyphs string[]?
---@field width number?
---@field height number?
---@field onComplete fun(result: table<string, unknown>)?
---@field audioSink OakIntroStateAudioSink?
---@field audioLifetime table<string, unknown>?
---@field textRenderer table<string, unknown>
---@field choiceText table<string, unknown>
---@field displayContext table<string, unknown>?
---@field namingOverrides table<string, table<string, unknown>>?
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
---@field _displayContext DisplayContext
---@field _namingOverrides table<string, table<string, unknown>>?
---@field _namingSession ApplicationPresentation? the per-entry naming session beside the profile controller
---@field _namingWindowState table<string, { x: number, y: number }>
---@field _blackHandoffPresented boolean
---@field _frozenStatus table<string, unknown>?
---@field _frozenAdapter table<string, unknown>?
---@field _setTextInput fun(self: OakIntroState, enabled: boolean)
---@field _acknowledgePresentedHandoff fun(self: OakIntroState)
---@field _clearFrozen fun(self: OakIntroState)
---@field _stepDialogue fun(self: OakIntroState, snapshot: table<string, unknown>?): table<string, unknown>?
---@field _measured fun(self: OakIntroState): table<string, unknown>
---@field _ensureNamingSession fun(self: OakIntroState): table<string, unknown>
---@field _disposeNamingSession fun(self: OakIntroState)
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
---@field _pointer fun(self: OakIntroState, x: number, y: number, pointerId: unknown)
---@field _applyNamingEvent fun(self: OakIntroState, event: { type: string, pointerId: unknown, x: number?, y: number? })
---@field mousepressed fun(self: OakIntroState, x: number, y: number, button: integer)
---@field mousemoved fun(self: OakIntroState, x: number, y: number, dx: number?, dy: number?, istouch: boolean?)
---@field mousereleased fun(self: OakIntroState, x: number, y: number, button: integer)
---@field touchpressed fun(self: OakIntroState, id: unknown, x: number, y: number)
---@field touchmoved fun(self: OakIntroState, id: unknown, x: number, y: number)
---@field touchreleased fun(self: OakIntroState, id: unknown, x: number, y: number)
---@field focus fun(self: OakIntroState, focused: boolean)
---@field dispose fun(self: OakIntroState)
local OakIntroState = {}
OakIntroState.__index = OakIntroState

-- Float slack keeps an exact source-frame boundary from losing a source tick.
local SOURCE_FRAME_HZ = 30
local SOURCE_FRAME_DURATION = 1 / SOURCE_FRAME_HZ
local SOURCE_FRAME_EPSILON = 1e-14

local function resolvePixelSurface(width, height)
  local bounds = { x = 0, y = 0, width = width, height = height }
  local preferredScale = math.max(1, math.floor(height / 192 + 0.5))
  local outputScale = PixelScale.fitPreferred(bounds, 256, 192, preferredScale)
  return PixelScale.cover(bounds, outputScale)
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
  if view.phase == "gender_select" then
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
  local displayContext = options.displayContext
  if displayContext == nil then
    displayContext = DisplayContext.new({})
  end
  local self
  local ok, result = pcall(function()
    local renderer = options.renderer
      or OakIntroRenderer.new({
        manifest = options.manifest,
        uiManifest = assert(
          options.uiManifest,
          "Oak state requires the validated field-UI manifest to build its renderer"
        ),
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
      glyphs = {},
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
      _displayContext = displayContext,
      _namingOverrides = options.namingOverrides,
      _namingSession = nil,
      _namingWindowState = {},
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
    if self.dialogueController then
      self:_stepDialogue()
    end
    self.controller:tick(1)
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
    if self.dialogueController then
      self:_stepDialogue()
    end
    self.controller:tick(1)
  end
  self:_sync()
end

---@return table<string, unknown> the current display facts
function OakIntroState:_measured()
  return self._displayContext:measure(self.width, self.height)
end

---@return ApplicationPresentation the owned naming session, created on first name_edit use
function OakIntroState:_ensureNamingSession()
  if self._namingSession ~= nil then
    return self._namingSession
  end
  local session =
    ApplicationPresentation.new(NamingInterface.withOverrides(self._namingOverrides), self._namingWindowState)
  self._namingSession = session
  return session
end

function OakIntroState:_disposeNamingSession()
  local session = self._namingSession
  self._namingSession = nil
  if session ~= nil then
    session.dispose(session)
  end
end

function OakIntroState:view()
  local view = self.controller:view()
  ---@cast view OakIntroStateView
  local surface = resolvePixelSurface(self.width, self.height)
  view.pixelSurface = surface
  local rootScale = assert(surface.placement.pixelScale, "Oak root surface keeps its integer physical scale")
  assert(rootScale == math.floor(rootScale), "Oak root compositing keeps an integer physical scale")
  view.layout = OakIntroLayout.compute(
    surface.logicalViewport.width,
    surface.logicalViewport.height,
    view,
    {},
    self.manifest,
    rootScale --[[@as integer]]
  )
  if view.phase == "name_edit" then
    local session = self:_ensureNamingSession()
    local snapshot = assert(view.namingScreen, "Oak name editing requires its Naming Screen snapshot")
    local measurement = assert(self:_measured(), "Oak naming needs its display facts")
    local resolved
    local ok, planOrErr = pcall(function()
      return session:resolve(measurement, snapshot)
    end)
    if not ok then
      self:_disposeNamingSession()
      error(planOrErr, 0)
    end
    resolved = assert(planOrErr, "Oak naming resolution returned no plan")
    view.namingPresentation = resolved
    local content = assert(resolved.content, "the naming plan needs its canonical content")
    view.layout.namingScreen = assert(content.layout, "the naming plan needs its canonical child layout")
  else
    self:_disposeNamingSession()
  end
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
  local overlay
  if self.dialogueController and self.dialogueRenderer then
    if self.dialogueController:isModal() then
      local function drawModalDialogue()
        self.dialogueRenderer:draw(self.dialogueController, view.dialoguePresentation)
      end
      overlay = drawModalDialogue
    elseif self._frozenAdapter and view.dialoguePresentation and retainsCompletedQuestion(view) then
      local function drawFrozenDialogue()
        self.dialogueRenderer:draw(self._frozenAdapter, view.dialoguePresentation)
      end
      overlay = drawFrozenDialogue
    end
  end
  self.renderer:draw(view, overlay)
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

---@param key string
---@param isrepeat boolean?
function OakIntroState:keypressed(key, _, isrepeat)
  if isrepeat and HgssInputBindings.isActionKey(key) then
    return
  end
  local direction = ({ ["left"] = "left", ["right"] = "right", ["up"] = "up", ["down"] = "down" })[key]
  local isAction = HgssInputBindings.isActionKey(key)
  local isCancel = HgssInputBindings.isCancelKey(key)
  if direction or isAction or isCancel then
    local action = direction or (isCancel and "cancel") or "confirm"
    if self.dialogueController and self.dialogueController:isModal() then
      self:_stepDialogue({ actionPressed = action == "confirm", cancelPressed = action == "cancel" })
      self:_sync()
      return
    end
    if self.controller:view().phase == "name_edit" then
      if isAction then
        -- HGSS A activates the focused naming cell or control; only Start submits.
        self.controller:press("confirm")
      elseif isCancel then
        self.controller:press("cancel")
      else
        self.controller:press(action)
      end
    else
      self.controller:press(action)
    end
  end
  self:_sync()
end

-- A consumed action-key press never becomes literal text: Space reaches the
-- naming screen as confirm, so its key event must not also insert a space
-- glyph (and likewise for newline). Direct typing of other glyphs still
-- inserts through the controller.
function OakIntroState:textinput(text)
  if self.controller:view().phase == "name_edit" and (text == " " or text == "\n" or text == "\r") then
    return
  end
  self.controller:inputText(text)
  self:_sync()
end

function OakIntroState:gamepadpressed(_, button)
  local action = ({
    dpup = "up",
    dpdown = "down",
    dpleft = "left",
    dpright = "right",
    a = "confirm",
    b = "cancel",
    start = "start",
  })[button]
  if
    action == "left"
    or action == "right"
    or action == "up"
    or action == "down"
    or action == "confirm"
    or action == "cancel"
    or action == "start"
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

-- Forwards one host pointer event to the owned naming session and applies
-- the semantic hit it returns. Presses activate cells and controls through
-- the leaf mapper; header moves drag the window inside the shared session
-- and releases end whichever capture the session holds. Never invents drag
-- state here: the session owns capture, translation, and cancellation.
---@param event { type: string, pointerId: unknown, x: number?, y: number? }
function OakIntroState:_applyNamingEvent(event)
  local view = self:view()
  if self.dialogueController and self.dialogueController:isModal() then
    self:_sync()
    return
  end
  assert(view.phase == "name_edit", "Oak naming pointer events require the name editor")
  local session = self:_ensureNamingSession()
  local snapshot = assert(view.namingScreen, "Oak name editing requires its Naming Screen snapshot")
  local mapped = session:mapInput({ event }, snapshot)
  for _, result in ipairs(mapped) do
    if result.type == "name_control" then
      self.controller:activateNameControl(result.id)
    elseif result.type == "name_cell" then
      self.controller:activateNameCell(result.row, result.column)
    end
  end
  self:_sync()
end

function OakIntroState:_pointer(x, y, pointerId)
  if self.controller:view().phase == "name_edit" then
    self:_applyNamingEvent({ type = "pointer_down", pointerId = pointerId, x = x, y = y })
    return
  end
  local view = self:view()
  if self.dialogueController and self.dialogueController:isModal() then
    self:_sync()
    return
  end
  local layout = assert(view.layout)
  local surface = assert(view.pixelSurface)
  local logicalX, logicalY = LayoutGeometry.hostToLogical(surface.placement, x, y)
  if logicalX == nil or logicalY == nil then
    self:_sync()
    return
  end
  if layout.confirmationButtons then
    for choice = 0, 1 do
      local entry = layout.confirmationButtons[choice]
      if entry and OakIntroLayout.contains(entry.rect, logicalX, logicalY) then
        self.controller:press(entry.key)
        self:_sync()
        return
      end
    end
  elseif layout.genderButtons then
    for gender = 0, 1 do
      local entry = layout.genderButtons[gender]
      if entry and OakIntroLayout.contains(entry.rect, logicalX, logicalY) then
        self.controller:press(entry.key)
        self:_sync()
        return
      end
    end
  end
  self:_sync()
end

function OakIntroState:mousepressed(x, y, button)
  if button == 1 then
    self:_pointer(x, y, "mouse")
  end
end

function OakIntroState:mousemoved(x, y, _, _, istouch)
  if istouch then
    return
  end
  if self.controller:view().phase ~= "name_edit" then
    return
  end
  self:_applyNamingEvent({ type = "pointer_move", pointerId = "mouse", x = x, y = y })
end

function OakIntroState:mousereleased(x, y, button)
  if button ~= 1 then
    return
  end
  if self.controller:view().phase ~= "name_edit" then
    return
  end
  self:_applyNamingEvent({ type = "pointer_up", pointerId = "mouse", x = x, y = y })
end

function OakIntroState:touchpressed(id, x, y)
  self:_pointer(x, y, id)
end

function OakIntroState:touchmoved(id, x, y)
  if self.controller:view().phase ~= "name_edit" then
    return
  end
  self:_applyNamingEvent({ type = "pointer_move", pointerId = id, x = x, y = y })
end

function OakIntroState:touchreleased(id, x, y)
  if self.controller:view().phase ~= "name_edit" then
    return
  end
  self:_applyNamingEvent({ type = "pointer_up", pointerId = id, x = x, y = y })
end

function OakIntroState:focus(focused)
  if not focused and self._namingSession ~= nil then
    self._namingSession:cancelPointers()
  end
end

function OakIntroState:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self:_disposeNamingSession()
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
