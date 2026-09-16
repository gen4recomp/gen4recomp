-- Reusable HGSS naming interaction state and retail keyboard topology.

local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

local NamingScreenController = {}

---@class NamingScreenOptions
---@field kind "player"|"pokemon"
---@field maxLength integer
---@field initialText string
---@field charmap table<string, integer>
---@field subject table<string, unknown>

---@class NamingScreenSnapshot
---@field kind "player"|"pokemon"
---@field page "upper"|"lower"|"symbols"
---@field cursor table<string, unknown>
---@field text string
---@field maxLength integer
---@field controls table<integer, table<string, unknown>>
---@field grid table<integer, table<integer, table<string, unknown>>>
---@field subject table<string, unknown>
---@field result table<string, string>?

---@class NamingScreenController
---@field new fun(options: NamingScreenOptions): NamingScreenController
---@field activateAt fun(self: NamingScreenController, row: integer, column: integer): boolean
---@field activateControl fun(self: NamingScreenController, id: string): boolean
---@field deleteGlyph fun(self: NamingScreenController): boolean
---@field inputText fun(self: NamingScreenController, text: string): boolean
---@field press fun(self: NamingScreenController, action: string): boolean
---@field result fun(self: NamingScreenController): table<string, string>?
---@field snapshot fun(self: NamingScreenController): table<string, unknown>
---@field text fun(self: NamingScreenController): string
NamingScreenController.__index = NamingScreenController

local ROWS, COLUMNS = 6, 13
local PAGES = { "upper", "lower", "symbols" }
local SPANS = { upper = { 1, 2 }, lower = { 3, 4 }, symbols = { 5, 6 }, back = { 9, 11 }, ok = { 12, 13 } }

local function sourceRow(text)
  local result = {}
  for glyph in Utf8Glyphs.iter(text) do
    result[#result + 1] = glyph
  end
  assert(#result == COLUMNS, "naming source row must contain thirteen cells")
  return result
end

local PAGE_ROWS = {
  upper = {
    sourceRow("ABCDEFGHIJ ,."),
    sourceRow("KLMNOPQRST '-"),
    sourceRow("UVWXYZ     ♂♀"),
    sourceRow("             "),
    sourceRow("0123456789   "),
  },
  lower = {
    sourceRow("abcdefghij ,."),
    sourceRow("klmnopqrst '-"),
    sourceRow("uvwxyz     ♂♀"),
    sourceRow("             "),
    sourceRow("0123456789   "),
  },
  symbols = {
    sourceRow(",.:;!?   ♂♀  "),
    sourceRow("“”‘’()       "),
    sourceRow("…·~@#%+-*/=  "),
    sourceRow("⊙○□△◇♠♥♦♣★♪  "),
    sourceRow("☀𝄞☂☃☺😆😧😠😴↑↓  "),
  },
}

local function homeCell(column)
  if column == 7 or column == 8 then
    return { kind = "blank" }
  end
  for id, span in pairs(SPANS) do
    if column >= span[1] and column <= span[2] then
      return { kind = "control", controlId = id }
    end
  end
  error("naming control row has no cell", 2)
end

local function count(text)
  local n = 0
  for _ in Utf8Glyphs.iter(text) do
    n = n + 1
  end
  return n
end

local function subjectCopy(subject)
  local result = {}
  for key, value in pairs(subject) do
    result[key] = value
  end
  return result
end

local function validateSubject(kind, subject)
  assert(type(subject) == "table" and subject.kind == kind, "naming subject kind must match controller kind")
  if kind == "player" then
    assert(subject.gender == 0 or subject.gender == 1, "player naming subject requires gender")
  else
    assert(
      type(subject.species) == "number" and subject.species % 1 == 0 and subject.species > 0,
      "pokemon naming subject requires species"
    )
    if subject.form ~= nil then
      assert(
        type(subject.form) == "number" and subject.form % 1 == 0 and subject.form >= 0,
        "pokemon naming subject form is invalid"
      )
    end
  end
end

local function pageCell(page, row, column)
  if row == 1 then
    return homeCell(column)
  end
  local glyph = PAGE_ROWS[page][row - 1][column]
  return { kind = "glyph", glyph = glyph }
end

local function makeGrid(page, charmap)
  local grid = {}
  for row = 1, ROWS do
    grid[row] = {}
    for column = 1, COLUMNS do
      local cell = pageCell(page, row, column)
      if cell.kind == "glyph" and charmap[cell.glyph] == nil then
        cell = { kind = "blank" }
      end
      grid[row][column] = cell
    end
  end
  return grid
end

local function sameCell(first, second)
  return first.kind == second.kind and first.glyph == second.glyph and first.controlId == second.controlId
end

---@param options { kind: "player"|"pokemon", maxLength: integer, initialText: string, charmap: table<string, integer>, subject: table<string, unknown> }
---@return NamingScreenController
function NamingScreenController.new(options)
  assert(type(options) == "table", "naming screen options are required")
  assert(options.kind == "player" or options.kind == "pokemon", "naming kind is invalid")
  assert(
    type(options.maxLength) == "number" and options.maxLength % 1 == 0 and options.maxLength > 0,
    "naming maxLength must be a positive integer"
  )
  assert(type(options.initialText) == "string", "naming initialText is required")
  assert(type(options.charmap) == "table", "naming charmap is required")
  validateSubject(options.kind, options.subject)
  assert(count(options.initialText) <= options.maxLength, "naming initialText exceeds maxLength")
  for glyph in Utf8Glyphs.iter(options.initialText) do
    assert(options.charmap[glyph] ~= nil, "naming initialText contains unsupported glyph")
  end
  local grids = {}
  for _, page in ipairs(PAGES) do
    grids[page] = makeGrid(page, options.charmap)
  end
  return setmetatable({
    _kind = options.kind,
    _maxLength = options.maxLength,
    _charmap = options.charmap,
    _subject = subjectCopy(options.subject),
    _page = "upper",
    _grids = grids,
    _cursor = { row = 2, column = 1 },
    _deltaColumn = 0,
    _text = options.initialText,
    _result = nil,
  }, NamingScreenController)
end

function NamingScreenController:_cell()
  return self._grids[self._page][self._cursor.row][self._cursor.column]
end

-- Retail cursor motion from pinned `NamingScreen_MoveKeyboardCursor`: one
-- wrapped step per press, skipping blank cells and repeated columns of the
-- same home-row control, with a remembered horizontal escape when moving
-- vertically out of a skipped home-row region.
function NamingScreenController:_move(direction)
  local previousRow = self._cursor.row
  local row, column = self._cursor.row, self._cursor.column
  local dr = direction == "up" and -1 or direction == "down" and 1 or 0
  local dc = direction == "left" and -1 or direction == "right" and 1 or 0
  local start = self:_cell()
  row = (row - 1 + dr) % ROWS + 1
  column = (column - 1 + dc) % COLUMNS + 1
  for _ = 1, ROWS * COLUMNS do
    local cell = self._grids[self._page][row][column]
    local repeated = cell.kind == "control" and sameCell(cell, start)
    if cell.kind ~= "blank" and not repeated then
      self._cursor = { row = row, column = column }
      if dc ~= 0 then
        self._deltaColumn = dc
      end
      return true
    end
    if previousRow == 1 and cell.kind == "blank" and dr ~= 0 and self._deltaColumn ~= 0 then
      column = (column - 1 + self._deltaColumn) % COLUMNS + 1
    else
      row = (row - 1 + dr) % ROWS + 1
      column = (column - 1 + dc) % COLUMNS + 1
    end
  end
  return false
end

function NamingScreenController:_insert(text)
  local incoming = count(text)
  for glyph in Utf8Glyphs.iter(text) do
    if self._charmap[glyph] == nil then
      return false
    end
  end
  if count(self._text) + incoming > self._maxLength then
    return false
  end
  self._text = self._text .. text
  return true
end

function NamingScreenController:inputText(text)
  assert(type(text) == "string", "naming text must be a string")
  return self._result == nil and self:_insert(text) or false
end

function NamingScreenController:deleteGlyph()
  if self._result ~= nil then
    return false
  end
  if self._text == "" then
    return true
  end
  local glyphs = {}
  for glyph in Utf8Glyphs.iter(self._text) do
    glyphs[#glyphs + 1] = glyph
  end
  glyphs[#glyphs] = nil
  self._text = table.concat(glyphs)
  return true
end

function NamingScreenController:submit()
  if self._result ~= nil then
    return false
  end
  self._result = { kind = "submit", text = self._text }
  return true
end

function NamingScreenController:cancel()
  if self._result ~= nil then
    return false
  end
  self._result = { kind = "cancel" }
  return true
end

function NamingScreenController:activateControl(id)
  assert(type(id) == "string", "naming control id is required")
  if self._result ~= nil then
    return false
  end
  if id == "upper" or id == "lower" or id == "symbols" then
    self._page = id
    return true
  elseif id:sub(1, 6) == "glyph:" then
    return self:_insert(id:sub(7))
  elseif id == "back" then
    return self:deleteGlyph()
  elseif id == "ok" then
    return self:submit()
  end
  error("unknown naming control: " .. id, 2)
end

function NamingScreenController:activateAt(row, column)
  assert(
    row >= 1 and row <= ROWS and row % 1 == 0 and column >= 1 and column <= COLUMNS and column % 1 == 0,
    "naming cell is invalid"
  )
  if self._result ~= nil then
    return false
  end
  local cell = self._grids[self._page][row][column]
  if cell.kind == "blank" then
    return false
  end
  self._cursor = { row = row, column = column }
  return cell.kind == "glyph" and self:_insert(cell.glyph) or self:activateControl(cell.controlId)
end

function NamingScreenController:press(action)
  assert(type(action) == "string", "naming action is required")
  if self._result ~= nil then
    return false
  end
  if action == "up" or action == "down" or action == "left" or action == "right" then
    return self:_move(action)
  elseif action == "confirm" or action == "a" then
    local cell = self:_cell()
    return cell.kind == "glyph" and self:_insert(cell.glyph) or self:activateControl(cell.controlId)
  elseif action == "back" or action == "backspace" then
    return self:deleteGlyph()
  elseif action == "submit" or action == "enter" then
    return self:submit()
  elseif action == "cancel" or action == "escape" or action == "b" then
    return self:cancel()
  end
  return false
end

function NamingScreenController:text()
  return self._text
end
function NamingScreenController:result()
  if self._result == nil then
    return nil
  end
  local result = { kind = self._result.kind }
  if self._result.kind == "submit" then
    result.text = self._result.text
  end
  return result
end

function NamingScreenController:snapshot()
  local cell = self:_cell()
  local controls = {}
  for _, id in ipairs({ "upper", "lower", "symbols", "back", "ok" }) do
    local span = SPANS[id]
    controls[#controls + 1] = {
      id = id,
      kind = id == "back" and "back" or id == "ok" and "submit" or "page",
      label = id == "upper" and "Upper"
        or id == "lower" and "Lower"
        or id == "symbols" and "Symbols"
        or id == "back" and "Back"
        or "OK",
      row = 1,
      firstColumn = span[1],
      lastColumn = span[2],
    }
  end
  local grid = {}
  for row = 1, ROWS do
    grid[row] = {}
    for column = 1, COLUMNS do
      local c = self._grids[self._page][row][column]
      grid[row][column] = { kind = c.kind, glyph = c.glyph, controlId = c.controlId }
    end
  end
  return {
    kind = self._kind,
    page = self._page,
    cursor = { row = self._cursor.row, column = self._cursor.column, controlId = cell.controlId },
    text = self._text,
    maxLength = self._maxLength,
    controls = controls,
    grid = grid,
    subject = subjectCopy(self._subject),
    result = self:result(),
  }
end

return NamingScreenController
