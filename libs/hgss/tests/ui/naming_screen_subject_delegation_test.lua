-- The Naming Screen renderer draws primitive chrome and text itself and
-- delegates only subject art to its host: one recording callback proves the
-- seam carries both player and Pokemon subjects without inspecting them.

local Assert = require("tests.support.Assert")
local NamingScreenRenderer = require("libs.hgss.src.ui.NamingScreenRenderer")

local T = { tests = {} }

local function graphicsFake()
  local calls = { push = 0, pop = 0, scaled = 0 }
  local graphics = {
    push = function()
      calls.push = calls.push + 1
    end,
    pop = function()
      calls.pop = calls.pop + 1
    end,
    translate = function() end,
    scale = function()
      calls.scaled = calls.scaled + 1
    end,
    setColor = function() end,
    rectangle = function() end,
    draw = function() end,
  }
  return graphics, calls
end

local function textFake()
  return {
    drawText = function() end,
    textWidth = function(value)
      return #value * 8
    end,
  }
end

local function canonicalLayout()
  local cells = {}
  for row = 1, 6 do
    cells[row] = {}
    for column = 1, 13 do
      cells[row][column] = { x = 28 + (column - 1) * 16, y = 88 + (row - 2) * 19, width = 17, height = 20 }
    end
  end
  return {
    surface = { x = 0, y = 0, width = 256, height = 192 },
    nameSlots = { x = 32, y = 22, width = 192, height = 24 },
    subject = { x = 8, y = 8, width = 48, height = 42 },
    keyboard = { x = 8, y = 58, width = 240, height = 106 },
    cells = cells,
    controls = {
      upper = { x = 25, y = 60, width = 32, height = 23 },
      lower = { x = 57, y = 60, width = 32, height = 23 },
      symbols = { x = 89, y = 60, width = 32, height = 23 },
      back = { x = 157, y = 60, width = 33, height = 23 },
      ok = { x = 197, y = 60, width = 33, height = 23 },
    },
  }
end

local function snapshot(subject)
  local grid = {}
  for row = 1, 6 do
    grid[row] = {}
    for column = 1, 13 do
      grid[row][column] = { kind = "glyph", glyph = "A" }
    end
  end
  return {
    kind = subject.kind,
    page = "upper",
    cursor = { row = 2, column = 1 },
    text = "",
    maxLength = 7,
    grid = grid,
    subject = subject,
  }
end

function T.tests.host_subject_callback_serves_player_and_pokemon_snapshots()
  local graphics, calls = graphicsFake()
  local seen = {}
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = textFake(),
    drawSubject = function(hostGraphics, subject, rect)
      seen[#seen + 1] = { graphics = hostGraphics, subject = subject, rect = rect }
    end,
  })
  local layout = canonicalLayout()
  local playerSubject = { kind = "player", gender = 1 }
  renderer:draw(snapshot(playerSubject), layout)
  local pokemonSubject = { kind = "pokemon", species = 25, form = 0 }
  renderer:draw(snapshot(pokemonSubject), layout)
  Assert.equal(#seen, 2)
  Assert.deepEqual(seen[1].subject, playerSubject)
  Assert.deepEqual(seen[1].rect, layout.subject)
  Assert.deepEqual(seen[2].subject, pokemonSubject)
  Assert.deepEqual(seen[2].rect, layout.subject)
  Assert.isNil(seen[2].subject.gender, "a Pokemon subject carries no gender for the renderer to read")
  Assert.equal(calls.push, calls.pop)
  Assert.equal(calls.scaled, 0)
  renderer:dispose()
end

function T.tests.subject_callback_is_a_required_constructor_collaborator()
  local graphics = graphicsFake()
  Assert.throws(function()
    NamingScreenRenderer.new({ graphics = graphics, text = textFake() })
  end, "a renderer without its host subject callback must fail at construction")
end

return T
