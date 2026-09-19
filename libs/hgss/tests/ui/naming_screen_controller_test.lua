-- Lower-layer contracts for the reusable HGSS Naming Screen.

local Assert = require("tests.support.Assert")
local NamingScreenController = require("libs.hgss.src.ui.NamingScreenController")
local NamingScreenLayout = require("libs.hgss.src.ui.NamingScreenLayout")

local T = { tests = {} }
local CHARMAP = {}
for code = string.byte(" "), string.byte("~") do
  CHARMAP[string.char(code)] = code
end

local function player(options)
  options = options or {}
  return NamingScreenController.new({
    kind = "player",
    maxLength = options.maxLength or 7,
    initialText = options.initialText or "",
    charmap = CHARMAP,
    subject = { kind = "player", gender = options.gender or 0 },
  })
end

function T.tests.snapshot_exposes_retail_pages_controls_and_source_surface()
  local view = player():snapshot()
  Assert.equal(view.page, "upper")
  Assert.equal(view.cursor.row, 2)
  Assert.equal(view.cursor.column, 1)
  Assert.equal(view.grid[2][1].glyph, "A")
  Assert.equal(view.grid[3][1].glyph, "K")
  Assert.equal(view.grid[4][1].glyph, "U")
  Assert.equal(view.grid[6][10].glyph, "9")
  Assert.equal(view.grid[1][1].controlId, "upper")
  Assert.equal(view.grid[1][13].controlId, "ok")
  Assert.equal(#view.controls, 5)
end

function T.tests.directional_navigation_skips_blanks_wraps_and_resolves_wide_controls()
  local controller = player()
  controller:press("left")
  Assert.equal(controller:snapshot().cursor.row, 2)
  Assert.equal(controller:snapshot().cursor.column, 13)
  Assert.equal(controller:snapshot().grid[2][13].glyph, ".")
  controller:press("down")
  Assert.equal(controller:snapshot().cursor.row, 3)
  controller:press("up")
  Assert.equal(controller:snapshot().cursor.row, 2)
  controller:activateAt(2, 1)
  for _ = 1, 5 do
    controller:press("down")
  end
  Assert.equal(controller:snapshot().cursor.controlId, "upper")
  controller:press("right")
  Assert.equal(controller:snapshot().cursor.controlId, "lower")
end

function T.tests.pages_back_ok_and_physical_input_share_one_mutation_path()
  local controller = player({ maxLength = 3 })
  Assert.isTrue(controller:inputText("AB"))
  Assert.isFalse(controller:inputText("CDE"))
  Assert.isTrue(controller:deleteGlyph())
  Assert.equal(controller:text(), "A")
  Assert.isTrue(controller:activateAt(2, 2))
  Assert.equal(controller:text(), "AB")
  Assert.isTrue(controller:activateControl("lower"))
  Assert.equal(controller:snapshot().page, "lower")
  Assert.isTrue(controller:activateControl("back"))
  Assert.equal(controller:text(), "A")
  Assert.isTrue(controller:activateControl("ok"))
  Assert.deepEqual(controller:result(), { kind = "submit", text = "A" })
end

function T.tests.pointer_and_gamepad_back_and_submit_are_semantic_results()
  local controller = player()
  Assert.isTrue(controller:activateAt(2, 1))
  Assert.equal(controller:text(), "A")
  Assert.isTrue(controller:press("cancel"))
  Assert.isNil(controller:result(), "the cancel alias deletes like Back, never emits app cancel")
  Assert.equal(controller:text(), "")
  Assert.isTrue(controller:activateAt(2, 2))
  Assert.equal(controller:text(), "B")
  Assert.isTrue(controller:press("submit"))
  Assert.deepEqual(controller:result(), { kind = "submit", text = "B" })
end

function T.tests.player_and_pokemon_subject_contracts_are_strict()
  local pokemon = NamingScreenController.new({
    kind = "pokemon",
    maxLength = 12,
    initialText = "",
    charmap = CHARMAP,
    subject = { kind = "pokemon", species = 25, form = 0 },
  })
  Assert.equal(pokemon:snapshot().subject.species, 25)
  Assert.throws(function()
    NamingScreenController.new({
      kind = "player",
      maxLength = 7,
      initialText = "",
      charmap = CHARMAP,
      subject = { kind = "pokemon", species = 25 },
    })
  end)
  Assert.throws(function()
    NamingScreenController.new({
      kind = "pokemon",
      maxLength = 7,
      initialText = "",
      charmap = CHARMAP,
      subject = { kind = "pokemon" },
    })
  end)
end

function T.tests.vertical_motion_out_of_a_skipped_home_region_uses_the_remembered_horizontal_delta()
  local controller = player()
  Assert.isTrue(controller:activateControl("symbols"))
  controller:press("right")
  Assert.isTrue(controller:activateAt(1, 10))
  Assert.equal(controller:snapshot().cursor.controlId, "back")
  controller:press("down")
  Assert.deepEqual(
    { controller:snapshot().cursor.row, controller:snapshot().cursor.column },
    { 2, 12 },
    "a vertical step from the home row skips blank glyphs sideways instead of dropping through them"
  )
end

function T.tests.physical_back_aliases_delete_and_start_submits_without_cancel()
  local controller = player({ maxLength = 7 })
  Assert.isTrue(controller:inputText("AB"))
  Assert.isTrue(controller:press("b"))
  Assert.isNil(controller:result(), "physical B deletes like Back, never emits app cancel")
  Assert.equal(controller:text(), "A")
  Assert.isTrue(controller:press("cancel"))
  Assert.isNil(controller:result(), "the cancel alias deletes like Back, never emits app cancel")
  Assert.equal(controller:text(), "")
  Assert.isTrue(controller:press("escape"))
  Assert.isNil(controller:result(), "the escape alias deletes like Back, never emits app cancel")
  Assert.equal(controller:text(), "")
  Assert.isTrue(controller:inputText("C"))
  Assert.isTrue(controller:press("start"))
  Assert.deepEqual(controller:result(), { kind = "submit", text = "C" })
end

function T.tests.layout_keeps_controls_inside_canonical_surface_at_integer_scale()
  local layout = NamingScreenLayout.compute({ x = 0, y = 0, width = 768, height = 576 })
  Assert.deepEqual(layout.surface, { x = 256, y = 192, width = 256, height = 192 })
  Assert.isNil(layout.placement, "the naming child must not own a placement")
  for id, region in pairs(layout.controls) do
    Assert.isTrue(
      region.x >= 0 and region.y >= 0 and region.x + region.width <= 256 and region.y + region.height <= 192,
      id .. " is outside surface"
    )
  end
  for row = 1, 6 do
    for column = 1, 13 do
      local region = layout.cells[row][column]
      Assert.isTrue(region.x + region.width <= 256 and region.y + region.height <= 192)
    end
  end
end

return T
