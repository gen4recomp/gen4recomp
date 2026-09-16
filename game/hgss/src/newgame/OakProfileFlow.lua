-- Player profile selection, name editing, and finalization state for Oak intro.

local NewGame = require("game.hgss.src.newgame.NewGame")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local NamingScreenController = require("libs.hgss.src.ui.NamingScreenController")

---@class OakProfileFlowOptions
---@field candidate table<string, unknown>
---@field audio GameSound
---@field playerDataContext { charmap: table<string, integer>, frameIndexes: table<integer, boolean> }
---@field randomU32 fun(): number

---@class OakProfileFlow
---@field new fun(options: OakProfileFlowOptions): OakProfileFlow
---@field private _candidate table<string, unknown>
---@field private _audio GameSound
---@field private _playerDataContext { charmap: table<string, integer>, frameIndexes: table<integer, boolean> }
---@field private _randomU32 fun(): number
---@field private _naming NamingScreenController?
---@field private _genderSelection integer
---@field private _name string
---@field private _confirmationChoice { kind: string, selected: integer }?
---@field private _result table<string, unknown>?
local OakProfileFlow = {}
OakProfileFlow.__index = OakProfileFlow

local DEFAULT_PROFILE_NAMES = { [0] = "Ethan", [1] = "Lyra" }

local function appendGlyphs(text)
  local glyphs = {}
  for glyph in Utf8Glyphs.iter(text) do
    glyphs[#glyphs + 1] = glyph
  end
  return glyphs
end

local function isBlankName(name)
  for glyph in Utf8Glyphs.iter(name) do
    if glyph ~= " " then
      return false
    end
  end
  return true
end

local function assertSelectionIndex(index)
  assert(
    type(index) == "number"
      and index == index
      and index ~= math.huge
      and index ~= -math.huge
      and index == math.floor(index),
    "selection index must be a finite integer"
  )
  assert(index >= 0 and index < 2, "selection index is out of range")
  ---@cast index integer
  return index
end

function OakProfileFlow.new(options)
  assert(type(options) == "table", "Oak profile flow requires options")
  assert(
    type(options.candidate) == "table" and options.candidate.playerData == nil,
    "Oak intro requires a partial candidate"
  )
  assert(type(options.audio) == "table" and type(options.audio.play) == "function", "Oak profile flow requires audio")
  assert(
    type(options.playerDataContext) == "table" and type(options.playerDataContext.charmap) == "table",
    "Oak intro requires a generated font charmap"
  )
  assert(type(options.randomU32) == "function", "Oak intro requires a trainer ID provider")
  return setmetatable({
    _candidate = options.candidate,
    _audio = options.audio,
    _playerDataContext = options.playerDataContext,
    _randomU32 = options.randomU32,
    _naming = nil,
    _genderSelection = 0,
    _name = "",
    _confirmationChoice = nil,
    _result = nil,
  }, OakProfileFlow)
end

function OakProfileFlow:_playSelectionEffect()
  self._audio:play("SEQ_SE_DP_SELECT")
end

function OakProfileFlow:gender()
  return self._genderSelection
end

function OakProfileFlow:name()
  return self._name
end

function OakProfileFlow:candidate()
  return self._candidate
end

function OakProfileFlow:result()
  return self._result
end

function OakProfileFlow:confirmationChoice()
  return self._confirmationChoice
      and {
        kind = self._confirmationChoice.kind,
        selected = self._confirmationChoice.selected,
      }
    or nil
end

function OakProfileFlow:beginConfirmation(kind)
  assert(kind == "gender" or kind == "name", "unknown Oak confirmation kind: " .. tostring(kind))
  self._confirmationChoice = { kind = kind, selected = 0 }
end

function OakProfileFlow:selectConfirmation(index)
  assert(self._confirmationChoice ~= nil, "Oak confirmation choice is not active")
  index = assertSelectionIndex(index)
  local changed = self._confirmationChoice.selected ~= index
  self._confirmationChoice.selected = index
  if changed then
    self:_playSelectionEffect()
  end
  return changed
end

function OakProfileFlow:focusGender(index)
  index = assertSelectionIndex(index)
  local changed = self._genderSelection ~= index
  self._genderSelection = index
  if changed then
    self:_playSelectionEffect()
  end
  return changed
end

function OakProfileFlow:activateGender(index)
  index = assertSelectionIndex(index)
  self._genderSelection = index
  self:_playSelectionEffect()
  return true
end

function OakProfileFlow:resolveConfirmation(selected)
  assert(self._confirmationChoice ~= nil, "Oak confirmation choice is not active")
  selected = assertSelectionIndex(selected)
  self:_playSelectionEffect()
  local kind = self._confirmationChoice.kind
  self._confirmationChoice = nil
  if kind == "gender" then
    return selected == 0 and "name_prompt" or "gender_question"
  elseif kind == "name" then
    return selected == 0 and "final_dialogue" or "gender_question"
  end
  error("unknown Oak confirmation kind: " .. tostring(kind), 0)
end

function OakProfileFlow:enterNameEditor()
  self._name = ""
  self._naming = NamingScreenController.new({
    kind = "player",
    maxLength = 7,
    initialText = "",
    charmap = self._playerDataContext.charmap,
    subject = { kind = "player", gender = self._genderSelection },
  })
end

function OakProfileFlow:activateNameCell(row, column)
  assert(self._naming ~= nil, "Oak naming screen is not active")
  local accepted = self._naming:activateAt(row, column)
  self._name = self._naming:text()
  local result = self._naming:result()
  if result and result.kind == "submit" then
    accepted = self:submitName()
  end
  return accepted
end

function OakProfileFlow:activateNameControl(id)
  assert(self._naming ~= nil, "Oak naming screen is not active")
  local accepted = self._naming:activateControl(id)
  self._name = self._naming:text()
  local result = self._naming:result()
  if result and result.kind == "submit" then
    accepted = self:submitName()
  end
  return accepted
end

function OakProfileFlow:namingResult()
  return self._naming and self._naming:result() or nil
end

function OakProfileFlow:inputText(text)
  assert(type(text) == "string", "Oak text input must be a string")
  assert(self._naming ~= nil, "Oak naming screen is not active")
  local accepted = self._naming:inputText(text)
  self._name = self._naming:text()
  return accepted
end

function OakProfileFlow:deleteGlyph()
  assert(self._naming ~= nil, "Oak naming screen is not active")
  local accepted = self._naming:deleteGlyph()
  self._name = self._naming:text()
  return accepted
end

function OakProfileFlow:submitName()
  if #appendGlyphs(self._name) > 7 then
    return false
  end
  if isBlankName(self._name) then
    self._name = assert(DEFAULT_PROFILE_NAMES[self._genderSelection])
  end
  return #appendGlyphs(self._name) >= 1
end

function OakProfileFlow:pressName(action)
  assert(self._naming ~= nil, "Oak naming screen is not active")
  if action == "cancel" or action == "escape" or action == "b" then
    return false
  end
  local accepted = self._naming:press(action)
  self._name = self._naming:text()
  if action == "confirm" or action == "submit" or action == "yes" then
    local result = self._naming:result()
    if result and result.kind == "submit" then
      accepted = self:submitName()
      return accepted, accepted and "submit" or nil
    end
  end
  return accepted
end

function OakProfileFlow:finalize()
  local finalized, failure = NewGame.finalize(self._candidate, {
    name = self._name,
    gender = self._genderSelection,
  }, {
    randomU32 = self._randomU32,
    playerDataContext = self._playerDataContext,
  })
  assert(finalized, failure and failure.message or "Oak profile finalization failed")
  self._result = finalized
  return finalized
end

function OakProfileFlow:inputFocus()
  return self._naming and self._naming:snapshot().cursor or nil
end

function OakProfileFlow:snapshot()
  return {
    genderFocus = self._genderSelection,
    name = self._name,
    namingScreen = self._naming and self._naming:snapshot() or nil,
    confirmationChoice = self:confirmationChoice(),
  }
end

return OakProfileFlow
