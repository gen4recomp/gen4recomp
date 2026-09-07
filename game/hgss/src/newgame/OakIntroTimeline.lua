-- Deterministic scripted Oak timeline state and source-frame presentation.

local OakGreetingPolicy = require("game.hgss.src.newgame.OakGreetingPolicy")
local StandardFade = require("libs.hgss.src.presentation.StandardFade")

---@class OakIntroTimelineOptions
---@field clock { nowLocal: fun(): LocalCivilTime }
---@field audio GameSound
---@field messages table<string, string|table<string, unknown>>
---@field assets table<string, unknown>

---@class OakIntroTimeline
---@field new fun(options: OakIntroTimelineOptions): OakIntroTimeline
---@field _clock { nowLocal: fun(): LocalCivilTime }
---@field _audio GameSound
---@field _messages table<string, string|table<string, unknown>>
---@field _assets table<string, unknown>
---@field _events table<integer, { kind: string, value: string, frame: integer }>
---@field _sourceFrames integer
---@field _phase string
---@field _timer integer
---@field _message string|table<string, unknown>|nil
---@field _messageKey string|nil
---@field _visual string
---@field _visualFrameIndex integer
---@field _visualFrameTimer integer?
---@field _sceneBrightness integer
---@field _revealBrightness integer
---@field _revealOpacity integer
---@field _finalFadeAlpha number
---@field _handoffFade StandardFade|nil
---@field _revealFrameIndex integer|nil
---@field _revealFrameTimer integer|nil
---@field _revealWidget string|nil
---@field _oakBgScrollX number
---@field _genderCompositionProgress number
---@field _genderCompositionTimer integer
---@field _nameCompositionProgress number
---@field _nameCompositionTimer integer
---@field _focusTimer integer
---@field _focusBlinkDelta number
---@field _disposed boolean
---@field _started boolean
local OakIntroTimeline = {}
OakIntroTimeline.__index = OakIntroTimeline

local GREETING_WAIT = 40
local MUSIC_FADE_FRAMES = 6
local OAK_REVEAL_WAIT = 30
local OAK_SLIDE_FRAMES = 26
local BALL_OPEN_WAIT = 30
local MARILL_CRY_WAIT = 40
local MARILL_HIDE_WAIT = 30
local NAME_LAUNCH_WAIT = 40
local FINAL_FULL_ART_HOLD = 30
local FINAL_FADE_FRAMES = 1
local OAK_BG_SCROLL_END_X = -52
local GENDER_COMPOSITION_FRAMES = 26
local REVEAL_ANIMATION_UNITS_PER_SOURCE_FRAME = 2

local function requireMessage(messages, key)
  local message = messages[key]
  assert(type(message) == "string" or type(message) == "table", "generated Oak message is missing: " .. key)
  return message
end

local function framesFor(assets, visual)
  assets = assets.widgets or assets
  local asset = assets[visual]
  return asset and asset.frames or nil
end

local function animationFor(assets, visual)
  assets = assets.widgets or assets
  return assets[visual]
end

local function focusBlinkDelta(timer)
  local deg = (timer % 36) * 10
  local rad = math.rad(deg)
  local value = math.sin(rad) * 8
  if value >= 0 then
    return math.floor(value + 0.5)
  end
  return math.ceil(value - 0.5)
end

function OakIntroTimeline.new(options)
  assert(type(options) == "table", "Oak intro timeline requires options")
  assert(
    type(options.clock) == "table" and type(options.clock.nowLocal) == "function",
    "Oak intro requires a local clock"
  )
  assert(type(options.audio) == "table", "Oak intro timeline requires audio")
  assert(type(options.messages) == "table", "Oak intro requires generated messages")
  return setmetatable({
    _clock = options.clock,
    _audio = options.audio,
    _messages = options.messages,
    _assets = options.assets or {},
    _phase = "opening_wait",
    _timer = GREETING_WAIT,
    _started = false,
    _disposed = false,
    _sourceFrames = 0,
    _message = nil,
    _messageKey = nil,
    _visual = "background",
    _visualFrameIndex = 1,
    _visualFrameTimer = nil,
    _sceneBrightness = 0,
    _revealBrightness = 0,
    _revealOpacity = 16,
    _finalFadeAlpha = 0,
    _handoffFade = nil,
    _revealFrameIndex = nil,
    _revealFrameTimer = nil,
    _revealWidget = nil,
    _oakBgScrollX = 0,
    _genderCompositionProgress = 0,
    _genderCompositionTimer = 0,
    _nameCompositionProgress = 0,
    _nameCompositionTimer = 0,
    _focusTimer = 0,
    _focusBlinkDelta = 0,
    _events = {},
  }, OakIntroTimeline)
end

function OakIntroTimeline:_setVisual(visual)
  self._visual = visual
  self._visualFrameIndex = 1
  local frames = framesFor(self._assets, visual)
  self._visualFrameTimer = frames and assert(frames[1].duration) or nil
end

function OakIntroTimeline:_advanceVisual()
  local frames =
    assert(framesFor(self._assets, self._visual), "generated visual animation is missing: " .. self._visual)
  self._visualFrameTimer = assert(self._visualFrameTimer) - 1
  if self._visualFrameTimer > 0 then
    return false
  end
  if self._visualFrameIndex == #frames then
    if self._phase == "marill_cry_wait" then
      self._visualFrameIndex = 1
    else
      return true
    end
  else
    self._visualFrameIndex = self._visualFrameIndex + 1
  end
  self._visualFrameTimer = assert(frames[self._visualFrameIndex].duration)
  return false
end

function OakIntroTimeline:_startReveal(visual)
  local animation = animationFor(self._assets, visual)
  assert(
    animation ~= nil and type(animation.frames) == "table" and #animation.frames > 0,
    "generated Oak animation is missing: " .. visual
  )
  local mode = animation.playMode
  assert(
    mode == "forward" or mode == "forward_loop" or mode == "reverse" or mode == "reverse_loop",
    "unsupported intro animation play mode: " .. tostring(mode)
  )
  self._revealWidget = visual
  if mode == "reverse" or mode == "reverse_loop" then
    self._revealFrameIndex = #animation.frames
  else
    self._revealFrameIndex = 1
  end
  self._revealFrameTimer = assert(animation.frames[self._revealFrameIndex].duration)
end

function OakIntroTimeline:_advanceReveal()
  local visual = assert(self._revealWidget)
  local animation = animationFor(self._assets, visual)
  assert(
    animation ~= nil and type(animation.frames) == "table" and #animation.frames > 0,
    "generated Oak animation is missing: " .. visual
  )
  local frames = animation.frames
  local mode = animation.playMode
  local loopStart = animation.loopStartFrameIdx
  assert(
    type(loopStart) == "number" and loopStart % 1 == 0 and loopStart >= 0 and loopStart < #frames,
    "generated Oak animation loop start is invalid: " .. visual
  )
  local loopFirst = math.floor(loopStart + 1)
  if mode ~= "forward" and mode ~= "forward_loop" and mode ~= "reverse" and mode ~= "reverse_loop" then
    error("unsupported intro animation play mode: " .. tostring(mode), 0)
  end

  local units = REVEAL_ANIMATION_UNITS_PER_SOURCE_FRAME
  while units > 0 do
    local frameRemaining = assert(self._revealFrameTimer)
    if units < frameRemaining then
      self._revealFrameTimer = frameRemaining - units
      return false
    end
    units = units - frameRemaining
    if mode == "forward" then
      if self._revealFrameIndex == #frames then
        return true
      end
      self._revealFrameIndex = self._revealFrameIndex + 1
    elseif mode == "forward_loop" then
      if self._revealFrameIndex == #frames then
        self._revealFrameIndex = loopFirst
      else
        self._revealFrameIndex = self._revealFrameIndex + 1
      end
    elseif mode == "reverse" then
      if self._revealFrameIndex == 1 then
        return true
      end
      self._revealFrameIndex = self._revealFrameIndex - 1
    else -- reverse_loop
      if self._revealFrameIndex == loopFirst then
        self._revealFrameIndex = #frames
      else
        self._revealFrameIndex = self._revealFrameIndex - 1
      end
    end
    self._revealFrameTimer = assert(frames[self._revealFrameIndex].duration)
  end
  return false
end

function OakIntroTimeline:_event(kind, value)
  self._events[#self._events + 1] = { kind = kind, value = value, frame = self._sourceFrames }
end

function OakIntroTimeline:_setMessage(key)
  self._message = requireMessage(self._messages, key)
  self._messageKey = key
  self:_event("message", key)
end

function OakIntroTimeline:setMessage(key)
  self:_setMessage(key)
end

function OakIntroTimeline:_startAppearance()
  self:_startReveal("marill_appear")
  self._revealBrightness = 16
  self._phase = "marill_appear"
end

function OakIntroTimeline:_startCry()
  self:_startReveal("marill")
  self._revealBrightness = 0
  self._audio:playCry(184, 0)
  self:_event("marill_appears", "marill")
  self._phase = "marill_cry_wait"
  self._timer = MARILL_CRY_WAIT
end

function OakIntroTimeline:_enterHandoffCover()
  self._handoffFade = StandardFade.new({ direction = "out", color = 0 })
  self._finalFadeAlpha = 0
  self._phase = "shrink_handoff_cover"
end

function OakIntroTimeline:_enterNameEditor()
  self._phase = "name_edit"
  self:_setVisual("background")
  self:_event("name_editor", "opened")
end

function OakIntroTimeline:_finishShrink(gender)
  self:_setVisual(gender == 0 and "shrink_male" or "shrink_female")
  if framesFor(self._assets, self._visual) == nil then
    self:_enterHandoffCover()
  else
    self._phase = "shrink_animation"
  end
end

function OakIntroTimeline:beginGenderQuestion()
  self._phase = "gender_question"
  self:_setMessage("profile.gender_question")
end

function OakIntroTimeline:beginGenderComposition()
  self._phase = "gender_composition_transition"
  self._genderCompositionTimer = GENDER_COMPOSITION_FRAMES
end

function OakIntroTimeline:beginNameComposition()
  self._phase = "name_composition_transition"
  self._nameCompositionTimer = GENDER_COMPOSITION_FRAMES
  self._nameCompositionProgress = 0
  self:_setVisual("oak")
end

function OakIntroTimeline:beginNameLaunch()
  self._phase = "name_launch_wait"
  self._timer = NAME_LAUNCH_WAIT
end

function OakIntroTimeline:beginNamePrompt()
  self._phase = "name_prompt"
  self:_setMessage("profile.name_prompt")
end

function OakIntroTimeline:beginFinalDialogue()
  self._phase = "final_dialogue"
  self:_setMessage("profile.final")
end

function OakIntroTimeline:beginFinalFade(gender)
  self._phase = "final_fade_out"
  self._timer = FINAL_FADE_FRAMES
  self._finalFadeAlpha = 0
  self:_setVisual("background")
  self:_event("final_handoff_started", "player")
  self._finalGender = gender
end

function OakIntroTimeline:phase()
  return self._phase
end

function OakIntroTimeline:messageKey()
  return self._messageKey
end

function OakIntroTimeline:hasMessage()
  return self._message ~= nil
end

function OakIntroTimeline:completeMessage(key)
  assert(key == self._messageKey, "Oak dialogue completion is stale")
  assert(self._message ~= nil, "Oak dialogue completion has no active message")
  self._message = nil
  self._messageKey = nil
  if self._phase == "gender_confirm" or self._phase == "name_confirm" then
    return self._phase == "gender_confirm" and "gender" or "name"
  end
  return nil
end

function OakIntroTimeline:focusTimer()
  return self._focusTimer, self._focusBlinkDelta
end

function OakIntroTimeline:resetGenderFocus()
  self._focusTimer = 0
  self._focusBlinkDelta = 0
end

function OakIntroTimeline:profileComposition()
  return self._genderCompositionProgress, self._nameCompositionProgress
end

function OakIntroTimeline:press(action, profile)
  if action ~= "confirm" and action ~= "yes" then
    return false
  end
  if self._phase == "greeting" then
    self._audio:fadeMusicOut({ target = 0, durationTicks = MUSIC_FADE_FRAMES })
    self._phase = "fade_wait"
    self._timer = MUSIC_FADE_FRAMES
  elseif self._phase == "oak_welcome" then
    self._phase = "oak_slide_right"
    self._timer = OAK_SLIDE_FRAMES
    self:_event("oak_slide", "right")
  elseif self._phase == "oak_world_inhabited" then
    self._phase = "ball_open_wait"
    self._timer = BALL_OPEN_WAIT
    self:_startReveal("ball_open")
    self:_event("ball_opened", "ball_open")
  elseif self._phase == "oak_live_alongside" then
    self._phase = "marill_hide"
    self._revealOpacity = 16
    self:_setVisual("oak")
    self:_event("marill_hidden", "marill")
  elseif self._phase == "oak_tell_about_yourself" then
    self:beginGenderQuestion()
  elseif self._phase == "gender_question" then
    local genderProgress, nameProgress = self:profileComposition()
    if nameProgress > 0 then
      self._phase = "name_composition_return"
      self._nameCompositionTimer = GENDER_COMPOSITION_FRAMES
    elseif genderProgress < 1 then
      self:beginGenderComposition()
    else
      self._phase = "gender_select"
      self._focusTimer = 0
      self._focusBlinkDelta = 0
    end
  elseif self._phase == "name_prompt" then
    self:beginNameLaunch()
  elseif self._phase == "final_dialogue" then
    self:beginFinalFade(profile:gender())
  else
    return false
  end
  return true
end

---@param self OakIntroTimeline
---@param gender integer
---@return boolean
local function stepComposition(self, gender)
  if self._phase == "gender_composition_transition" then
    self._genderCompositionTimer = self._genderCompositionTimer - 1
    self._genderCompositionProgress = (GENDER_COMPOSITION_FRAMES - self._genderCompositionTimer)
      / GENDER_COMPOSITION_FRAMES
    if self._genderCompositionTimer == 0 then
      self._genderCompositionProgress = 1
      self._phase = "gender_select"
      self._focusTimer = 0
      self._focusBlinkDelta = 0
    end
    return true
  elseif self._phase == "name_composition_transition" then
    self._nameCompositionTimer = self._nameCompositionTimer - 1
    self._nameCompositionProgress = (GENDER_COMPOSITION_FRAMES - self._nameCompositionTimer) / GENDER_COMPOSITION_FRAMES
    if self._nameCompositionTimer == 0 then
      self._nameCompositionProgress = 1
      self._phase = "name_confirm"
      self:_setVisual("oak")
      self:_setMessage(gender == 0 and "profile.name_confirm.male" or "profile.name_confirm.female")
    end
    return true
  elseif self._phase == "name_composition_return" then
    self._nameCompositionTimer = self._nameCompositionTimer - 1
    self._nameCompositionProgress = self._nameCompositionTimer / GENDER_COMPOSITION_FRAMES
    if self._nameCompositionTimer == 0 then
      self._nameCompositionProgress = 0
      self._phase = "gender_select"
      self._focusTimer = 0
      self._focusBlinkDelta = 0
    end
    return true
  end
  return false
end

---@param self OakIntroTimeline
---@return boolean, boolean
local function stepPresentation(self)
  if self._phase == "shrink_animation" then
    if self:_advanceVisual() then
      self:_enterHandoffCover()
    end
    return true, false
  elseif self._phase == "shrink_handoff_cover" then
    local fade = assert(self._handoffFade, "post-shrink cover fade is missing")
    local coefficient = fade:updateSourceFrame()
    self._finalFadeAlpha = coefficient / 16
    if fade:status().completed then
      self._phase = "handoff_black"
    end
    return true, false
  end
  if self._phase == "ball_open_wait" then
    self:_advanceReveal()
  elseif self._phase == "scene_flash" then
    self._sceneBrightness = math.max(0, self._sceneBrightness - 4)
    if self._sceneBrightness == 0 then
      self:_startAppearance()
    end
  elseif self._phase == "marill_appear" then
    if self:_advanceReveal() then
      self._phase = "marill_brightness_fade"
      self._revealBrightness = 16
    end
  elseif self._phase == "marill_brightness_fade" then
    self._revealBrightness = math.max(0, self._revealBrightness - 1)
    if self._revealBrightness == 0 then
      self:_startCry()
      return false, true
    end
  elseif self._revealWidget ~= nil then
    self:_advanceReveal()
  end
  return false, false
end

---@param self OakIntroTimeline
---@return boolean
local function stepOpeningScene(self)
  if self._phase == "opening_wait" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self:_setMessage(OakGreetingPolicy.messageKey(self._clock:nowLocal()))
      self._phase = "greeting"
      self:_setVisual("background")
    end
  elseif self._phase == "fade_wait" then
    self._timer = self._timer - 1
    if self._timer <= 0 and not self._audio:isMusicFadeActive() then
      self._audio:stopMusic()
      self._audio:playMusic("SEQ_GS_STARTING2")
      self._phase = "oak_reveal_wait"
      self._timer = OAK_REVEAL_WAIT
      self:_setVisual("oak")
      self:_event("oak_revealed", "oak")
    end
  elseif self._phase == "oak_reveal_wait" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self._phase = "oak_welcome"
      self:_setMessage("oak.welcome")
    end
  elseif self._phase == "oak_slide_right" or self._phase == "oak_slide_left" then
    self._timer = self._timer - 1
    local progress = (OAK_SLIDE_FRAMES - self._timer) / OAK_SLIDE_FRAMES
    self._oakBgScrollX = self._phase == "oak_slide_right" and OAK_BG_SCROLL_END_X * progress
      or OAK_BG_SCROLL_END_X * (1 - progress)
    if self._timer == 0 then
      if self._phase == "oak_slide_right" then
        self._oakBgScrollX = OAK_BG_SCROLL_END_X
        self._phase = "oak_world_inhabited"
        self:_setMessage("oak.world_inhabited")
      else
        self._oakBgScrollX = 0
        self._phase = "oak_tell_about_yourself"
        self:_setMessage("oak.tell_about_yourself")
      end
    end
  elseif self._phase == "ball_open_wait" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self:_event("ball_flash", "opening")
      self._audio:play("SEQ_SE_DP_BOWA2")
      self._sceneBrightness = 16
      self._phase = "scene_flash"
    end
  else
    return false
  end
  return true
end

---@param self OakIntroTimeline
---@param gender integer
---@param startedCry boolean
local function stepOpeningProfile(self, gender, startedCry)
  if self._phase == "marill_cry_wait" and not startedCry then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self._phase = "oak_live_alongside"
      self:_setVisual("oak")
      self:_setMessage("oak.live_alongside")
    end
  elseif self._phase == "marill_hide" then
    self._revealOpacity = math.max(0, self._revealOpacity - 1)
    if self._revealOpacity == 0 then
      self._revealWidget = nil
      self._revealFrameIndex = nil
      self._revealFrameTimer = nil
      self._phase = "marill_hide_wait"
      self._timer = MARILL_HIDE_WAIT
    end
  elseif self._phase == "marill_hide_wait" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self._phase = "oak_slide_left"
      self._timer = OAK_SLIDE_FRAMES
      self:_setVisual("oak")
      self:_event("oak_slide", "left")
    end
  elseif self._phase == "name_launch_wait" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self:_enterNameEditor()
    end
  elseif self._phase == "final_fade_out" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self._finalFadeAlpha = 1
      self:_setVisual(gender == 0 and "male" or "female")
      self._phase = "final_full_art_fade_in"
      self._timer = FINAL_FADE_FRAMES
    end
  elseif self._phase == "final_full_art_fade_in" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self._finalFadeAlpha = 0
      self._phase = "final_full_art_hold"
      self._timer = FINAL_FULL_ART_HOLD
    end
  elseif self._phase == "final_full_art_hold" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self._audio:play("SEQ_SE_GS_HERO_SHUKUSHOU")
      self:_finishShrink(gender)
    end
  elseif self._phase == "gender_select" then
    self._focusBlinkDelta = focusBlinkDelta(self._focusTimer)
    self._focusTimer = self._focusTimer + 1
  end
end

---@param self OakIntroTimeline
---@param gender integer
---@param startedCry boolean
local function stepOpening(self, gender, startedCry)
  if not stepOpeningScene(self) then
    stepOpeningProfile(self, gender, startedCry)
  end
end

function OakIntroTimeline:tick(frames, gender)
  assert(type(frames) == "number" and frames % 1 == 0 and frames >= 0, "Oak tick count must be a non-negative integer")
  if self._disposed or not self._started then
    return
  end
  for _ = 1, frames do
    if self._phase == "complete" then
      break
    end
    self._sourceFrames = self._sourceFrames + 1
    self._audio:updateSoundFrame()
    if stepComposition(self, gender) then
      goto continue
    end
    local handled, startedCry = stepPresentation(self)
    if not handled then
      stepOpening(self, gender, startedCry)
    end
    ::continue::
  end
end

function OakIntroTimeline:start()
  assert(not self._disposed, "Oak intro is disposed")
  if self._started then
    return false
  end
  self._started = true
  self._audio:playMusic("SEQ_GS_STARTING")
  self:_event("started", "SEQ_GS_STARTING")
  return true
end

function OakIntroTimeline:beginGenderConfirm(gender)
  self._phase = "gender_confirm"
  self._focusTimer = 0
  self._focusBlinkDelta = 0
  self:_setMessage(gender == 0 and "profile.gender_confirm.male" or "profile.gender_confirm.female")
end

function OakIntroTimeline:beginNameConfirm()
  self._phase = "name_confirm"
end

function OakIntroTimeline:finish(result)
  self._phase = "complete"
  self:_event("handoff", result.saveId)
end

function OakIntroTimeline:confirmHandoffPresented()
  if self._disposed or not self._started or self._phase ~= "handoff_black" then
    return false
  end
  return true
end

function OakIntroTimeline:snapshot()
  return {
    phase = self._phase,
    message = self._message,
    visual = self._visual,
    visualFrameIndex = self._visualFrameIndex,
    sceneBrightness = self._sceneBrightness / 16,
    revealBrightness = self._revealBrightness / 16,
    revealOpacity = self._revealOpacity / 16,
    messageKey = self._messageKey,
    revealWidget = self._revealWidget,
    revealFrameIndex = self._revealFrameIndex,
    oakBgScrollX = self._oakBgScrollX,
    genderCompositionProgress = self._genderCompositionProgress,
    nameCompositionProgress = self._nameCompositionProgress,
    finalFadeAlpha = self._finalFadeAlpha,
    sourceFrames = self._sourceFrames,
    events = self._events,
    focusTimer = self._focusTimer,
    focusBlinkDelta = self._focusBlinkDelta,
  }
end

function OakIntroTimeline:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._audio:stopMusic()
end

return OakIntroTimeline
