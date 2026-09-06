-- Public Oak intro facade coordinating scripted timeline and profile state.

local OakIntroTimeline = require("game.hgss.src.newgame.OakIntroTimeline")
local OakProfileFlow = require("game.hgss.src.newgame.OakProfileFlow")

---@class OakIntroControllerOptions : OakIntroTimelineOptions, OakProfileFlowOptions
---@field candidate table<string, unknown> partial New Game candidate finalized only after profile confirmation
---@field clock { nowLocal: fun(): LocalCivilTime }
---@field audio GameSound
---@field messages table<string, string|table<string, unknown>>
---@field assets table<string, unknown>?
---@field playerDataContext { charmap: table<string, integer>, frameIndexes: table<integer, boolean> }
---@field randomU32 fun(): number
---@field virtualGlyphs string[]
---@field virtualKeyColumns integer?

---@class OakIntroEvent
---@field kind string
---@field value string
---@field frame integer

---@class OakIntroControllerView
---@field phase string
---@field message string|table<string, unknown>|nil
---@field visual string
---@field visualFrameIndex integer
---@field primaryWidget string|nil
---@field revealWidget string|nil
---@field oakBgScrollX number
---@field genderCompositionProgress number
---@field nameCompositionProgress number
---@field messageKey string|nil
---@field confirmationChoice { kind: "gender"|"name", selected: integer }?
---@field dialogue { message: string|table<string, unknown>|nil, messageKey: string? }?
---@field revealFrameIndex integer|nil
---@field sceneBrightness number
---@field revealBrightness number
---@field revealOpacity number
---@field finalFadeAlpha number
---@field genderFocus integer
---@field focusTimer integer
---@field focusBlinkDelta number
---@field name string
---@field virtualGlyphFocus integer
---@field virtualKeys table<integer, { kind: string, glyph: string? }>
---@field virtualKeyColumns integer
---@field nameInputEnabled boolean
---@field sourceFrames integer
---@field events OakIntroEvent[]

---@class OakIntroController
---@field new fun(options: OakIntroControllerOptions): OakIntroController
---@field private _timeline OakIntroTimeline
---@field private _profile OakProfileFlow
---@field private _started boolean
---@field private _disposed boolean
local OakIntroController = {}
OakIntroController.__index = OakIntroController

function OakIntroController.new(options)
  assert(type(options) == "table", "OakIntroController requires options")
  local timeline = OakIntroTimeline.new(options)
  local profile = OakProfileFlow.new(options)
  return setmetatable({
    _timeline = timeline,
    _profile = profile,
    _started = false,
    _disposed = false,
  }, OakIntroController)
end

function OakIntroController:_applyProfilePhase(phase)
  if phase == "name_prompt" then
    self._timeline:beginNamePrompt()
  elseif phase == "gender_question" then
    self._timeline:beginGenderQuestion()
  elseif phase == "final_dialogue" then
    self._timeline:beginFinalDialogue()
  else
    error("unknown Oak profile phase: " .. tostring(phase), 0)
  end
end

function OakIntroController:_applyGenderFocus(index)
  if self._profile:focusGender(index) then
    self._timeline:resetGenderFocus()
  end
end

function OakIntroController:tick(frames)
  assert(type(frames) == "number" and frames % 1 == 0 and frames >= 0, "Oak tick count must be a non-negative integer")
  if self._disposed or not self._started then
    return
  end
  for _ = 1, frames do
    local before = self._timeline:phase()
    if before == "complete" then
      break
    end
    self._timeline:tick(1, self._profile:gender())
    if before ~= "name_edit" and self._timeline:phase() == "name_edit" then
      self._profile:enterNameEditor()
    end
  end
end

function OakIntroController:confirmHandoffPresented()
  if self._disposed or not self._started or not self._timeline:confirmHandoffPresented() then
    return false
  end
  local result = self._profile:finalize()
  self._timeline:finish(result)
  return true
end

function OakIntroController:start()
  assert(not self._disposed, "Oak intro is disposed")
  if self._started then
    return false
  end
  self._started = true
  return self._timeline:start()
end

function OakIntroController:press(action)
  assert(type(action) == "string", "Oak semantic action must be a string")
  if self._disposed or not self._started or self._timeline:phase() == "complete" then
    return false
  end
  if self._timeline:hasMessage() then
    return false
  end

  local phase = self._timeline:phase()
  local confirmation = self._profile:confirmationChoice()
  if confirmation then
    local vertical = action == "up" or action == "down"
    if vertical then
      local index = action == "up" and 0 or 1
      local changed = confirmation.selected ~= index
      if changed then
        self._profile:selectConfirmation(index)
      end
      return true
    end
    if action == "confirm" then
      self:_applyProfilePhase(self._profile:resolveConfirmation(confirmation.selected))
      return true
    end
    if action == "yes" then
      self:_applyProfilePhase(self._profile:resolveConfirmation(0))
      return true
    end
    if action == "cancel" or action == "no" then
      self:_applyProfilePhase(self._profile:resolveConfirmation(1))
      return true
    end
    return false
  end

  if phase == "gender_select" then
    if action == "male" then
      self._profile:activateGender(0)
      self._timeline:beginGenderConfirm(0)
      return true
    elseif action == "female" then
      self._profile:activateGender(1)
      self._timeline:beginGenderConfirm(1)
      return true
    elseif action == "left" then
      self:_applyGenderFocus(0)
      return true
    elseif action == "right" then
      self:_applyGenderFocus(1)
      return true
    elseif action == "confirm" or action == "yes" then
      local gender = self._profile:gender()
      self._profile:activateGender(gender)
      self._timeline:beginGenderConfirm(gender)
      return true
    end
  elseif phase == "name_edit" then
    local accepted, submitted = self._profile:pressName(action)
    if submitted == "submit" and accepted then
      self._timeline:beginNameComposition()
    end
    return accepted
  else
    return self._timeline:press(action, self._profile)
  end
  return false
end

function OakIntroController:inputText(text)
  assert(type(text) == "string", "Oak text input must be a string")
  if self._disposed or self._timeline:phase() ~= "name_edit" then
    return false
  end
  return self._profile:inputText(text)
end

function OakIntroController:deleteGlyph()
  if self._disposed or self._timeline:phase() ~= "name_edit" then
    return false
  end
  return self._profile:deleteGlyph()
end

function OakIntroController:view()
  local timeline = self._timeline:snapshot()
  local profile = self._profile:snapshot()
  ---@type string?
  local primaryWidget = timeline.visual
  if primaryWidget == "background" then
    primaryWidget = timeline.phase == "marill_cry_wait" and "oak" or nil
  end
  local dialogue
  if timeline.message ~= nil then
    dialogue = { message = timeline.message, messageKey = assert(timeline.messageKey) }
  end
  return {
    phase = timeline.phase,
    message = timeline.message,
    visual = timeline.visual,
    visualFrameIndex = timeline.visualFrameIndex,
    sceneBrightness = timeline.sceneBrightness,
    revealBrightness = timeline.revealBrightness,
    revealOpacity = timeline.revealOpacity,
    genderFocus = profile.genderFocus,
    focusTimer = timeline.focusTimer,
    focusBlinkDelta = timeline.focusBlinkDelta,
    name = profile.name,
    virtualGlyphFocus = profile.virtualGlyphFocus,
    virtualKeys = profile.virtualKeys,
    virtualKeyColumns = profile.virtualKeyColumns,
    nameInputEnabled = timeline.phase == "name_edit",
    sourceFrames = timeline.sourceFrames,
    events = timeline.events,
    messageKey = timeline.messageKey,
    confirmationChoice = profile.confirmationChoice,
    dialogue = dialogue,
    primaryWidget = primaryWidget,
    revealWidget = timeline.revealWidget,
    revealFrameIndex = timeline.revealFrameIndex,
    oakBgScrollX = timeline.oakBgScrollX,
    genderCompositionProgress = timeline.genderCompositionProgress,
    nameCompositionProgress = timeline.nameCompositionProgress,
    finalFadeAlpha = timeline.finalFadeAlpha,
  }
end

function OakIntroController:messageCompleted(key)
  local confirmationKind = self._timeline:completeMessage(key)
  if confirmationKind then
    self._profile:beginConfirmation(confirmationKind)
    return true
  end
  return self._timeline:press("confirm", self._profile)
end

function OakIntroController:candidate()
  return self._profile:candidate()
end

function OakIntroController:result()
  return self._profile:result()
end

function OakIntroController:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._timeline:dispose()
end

return OakIntroController
