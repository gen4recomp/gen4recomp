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

function T.tests.presentation_state_rests_at_zero_ticks_and_glow_angle_180()
  local controller = player()
  local presentation = controller:snapshot().presentation
  Assert.isTrue(type(presentation) == "table", "the snapshot carries deterministic presentation state")
  Assert.equal(presentation.subjectTick, 0, "the subject clock rests at zero")
  Assert.equal(presentation.cursorTick, 0, "the cursor clock rests at zero")
  Assert.equal(presentation.glowAngle, 180, "the glow angle rests at 180")
end

function T.tests.fixed_update_advances_both_clocks_and_steps_the_glow_angle()
  local controller = player()
  Assert.isTrue(type(controller.updateFixed) == "function", "the controller advances presentation on a fixed update")
  controller:updateFixed()
  controller:updateFixed()
  local presentation = assert(controller:snapshot().presentation)
  Assert.equal(presentation.subjectTick, 2, "one subject tick per fixed update")
  Assert.equal(presentation.cursorTick, 2, "one cursor tick per fixed update")
  Assert.equal(presentation.glowAngle, 220, "the glow angle steps 20 degrees per fixed update")
end

function T.tests.glow_angle_wraps_to_zero_past_360_and_freezes_after_submit()
  local controller = player()
  Assert.isTrue(type(controller.updateFixed) == "function", "the controller advances presentation on a fixed update")
  controller:updateFixed()
  controller:updateFixed()
  controller:updateFixed()
  controller:updateFixed()
  controller:updateFixed()
  controller:updateFixed()
  controller:updateFixed()
  controller:updateFixed()
  controller:updateFixed()
  Assert.equal(controller:snapshot().presentation.glowAngle, 360, "180 plus nine steps reaches 360")
  controller:updateFixed()
  Assert.equal(controller:snapshot().presentation.glowAngle, 0, "an increment past 360 wraps to zero")
  controller:updateFixed()
  Assert.equal(controller:snapshot().presentation.glowAngle, 20, "the glow resumes from zero")
  Assert.isTrue(controller:activateControl("ok"))
  local frozen = assert(controller:snapshot().presentation)
  controller:updateFixed()
  Assert.deepEqual(controller:snapshot().presentation, frozen, "a submitted name stops advancing presentation state")
end

function T.tests.focus_movement_resets_cursor_age_and_glow_while_same_cell_keeps_them()
  local controller = player()
  Assert.isTrue(type(controller.updateFixed) == "function", "the controller advances presentation on a fixed update")
  controller:updateFixed()
  Assert.isTrue(controller:press("right"), "the focus moves to a new cell")
  local moved = assert(controller:snapshot().presentation)
  Assert.equal(moved.cursorTick, 0, "movement resets the cursor clock")
  Assert.equal(moved.glowAngle, 180, "movement resets the glow angle")
  Assert.equal(moved.subjectTick, 1, "movement leaves the subject clock alone")
  controller:updateFixed()
  local cursor = controller:snapshot().cursor
  Assert.isTrue(controller:activateAt(cursor.row, cursor.column) ~= nil, "refocusing the same cell is accepted")
  local kept = assert(controller:snapshot().presentation)
  Assert.equal(kept.cursorTick, 1, "refocusing the same cell keeps the cursor clock")
  Assert.equal(kept.glowAngle, 200, "refocusing the same cell keeps the glow angle")
  Assert.isTrue(controller:activateAt(3, 5), "direct focus moves to another cell")
  local direct = assert(controller:snapshot().presentation)
  Assert.equal(direct.cursorTick, 0, "direct focus resets the cursor clock through the same path")
  Assert.equal(direct.glowAngle, 180, "direct focus resets the glow angle through the same path")
end

-- One presentation tick keeps its current meaning, while an explicit tick
-- count advances every presentation clock by exactly that many steps so a
-- 60 Hz host can drive two ticks per 30 Hz source tick.
function T.tests.fixed_update_accepts_an_explicit_presentation_tick_count()
  local controller = player()
  controller:updateFixed(2)
  local presentation = assert(controller:snapshot().presentation)
  Assert.equal(presentation.subjectTick, 2, "two requested ticks advance the subject clock twice")
  Assert.equal(presentation.cursorTick, 2, "two requested ticks advance the cursor clock twice")
  Assert.equal(presentation.glowAngle, 220, "two requested ticks step the glow angle twice")
  controller:updateFixed()
  local defaulted = assert(controller:snapshot().presentation)
  Assert.equal(defaulted.subjectTick, 3, "an omitted count still advances one tick")
  controller:updateFixed(0)
  Assert.deepEqual(controller:snapshot().presentation, defaulted, "zero requested ticks leave presentation state alone")
  Assert.throws(function()
    controller:updateFixed(-1)
  end, "a negative tick count fails loudly")
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- test deliberately exercises a fractional tick count
    controller:updateFixed(1.5)
  end, "a fractional tick count fails loudly")
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
