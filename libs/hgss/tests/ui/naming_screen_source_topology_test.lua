-- The Naming Screen keeps the retail 6x13 topology but draws and hits it
-- with the source integer cursor/touch geometry, and D-pad movement follows
-- the source wrap/skip/repeat/delta rules instead of generic scanning.

local Assert = require("tests.support.Assert")
local NamingScreenController = require("libs.hgss.src.ui.NamingScreenController")
local NamingScreenLayout = require("libs.hgss.src.ui.NamingScreenLayout")

local T = { tests = {} }

local CHARMAP = {}
for code = string.byte(" "), string.byte("~") do
  CHARMAP[string.char(code)] = code
end

local function player()
  return NamingScreenController.new({
    kind = "player",
    maxLength = 7,
    initialText = "",
    charmap = CHARMAP,
    subject = { kind = "player", gender = 0 },
  })
end

local function cellAt(layout, row, column, x, y)
  for r = 1, 6 do
    for c = 1, 13 do
      if NamingScreenLayout.contains(layout.cells[r][c], x, y) then
        Assert.equal(r, row, "pointer row must match the source hit table")
        Assert.equal(c, column, "pointer column must match the source hit table")
        return
      end
    end
  end
  error("pointer hit no keyboard cell", 0)
end

local function controlAt(layout, id, x, y)
  for name, region in pairs(layout.controls) do
    if NamingScreenLayout.contains(region, x, y) then
      Assert.equal(name, id, "pointer control must match the source hit table")
      return
    end
  end
  error("pointer hit no home control", 0)
end

function T.tests.keyboard_hit_rectangles_use_source_integer_geometry()
  local layout = NamingScreenLayout.compute({ x = 0, y = 0, width = 256, height = 192 })
  Assert.deepEqual(layout.surface, { x = 0, y = 0, width = 256, height = 192 })
  -- First and last glyph cells from the source touch table.
  Assert.deepEqual(layout.cells[2][1], { x = 28, y = 88, width = 17, height = 20 })
  Assert.deepEqual(layout.cells[6][13], { x = 220, y = 164, width = 17, height = 20 })
  Assert.deepEqual(layout.cells[3][5], { x = 92, y = 107, width = 17, height = 20 })
  -- Home-row controls from the source touch table.
  Assert.deepEqual(layout.controls.upper, { x = 25, y = 60, width = 32, height = 23 })
  Assert.deepEqual(layout.controls.lower, { x = 57, y = 60, width = 32, height = 23 })
  Assert.deepEqual(layout.controls.symbols, { x = 89, y = 60, width = 32, height = 23 })
  Assert.deepEqual(layout.controls.back, { x = 157, y = 60, width = 33, height = 23 })
  Assert.deepEqual(layout.controls.ok, { x = 197, y = 60, width = 33, height = 23 })
  -- Cursor centers are published separately from hit rectangles.
  Assert.notNil(layout.cursorCenters, "cursor centers must be published apart from hit rectangles")
  Assert.deepEqual(layout.cursorCenters[2][1], { x = 26, y = 91 })
  Assert.deepEqual(layout.cursorCenters[6][13], { x = 218, y = 167 })
end

function T.tests.pointer_presses_map_to_source_semantic_cells()
  local layout = NamingScreenLayout.compute({ x = 0, y = 0, width = 256, height = 192 })
  controlAt(layout, "upper", 30, 70)
  controlAt(layout, "back", 170, 70)
  controlAt(layout, "ok", 210, 70)
  cellAt(layout, 2, 1, 36, 98)
  cellAt(layout, 6, 13, 228, 174)
end

function T.tests.dpad_wraps_skips_and_suppresses_repeated_home_controls()
  local controller = player()
  controller:press("left")
  Assert.deepEqual({ controller:snapshot().cursor.row, controller:snapshot().cursor.column }, { 2, 13 })
  controller:press("right")
  Assert.deepEqual({ controller:snapshot().cursor.row, controller:snapshot().cursor.column }, { 2, 1 })
  controller:press("up")
  Assert.deepEqual({ controller:snapshot().cursor.row, controller:snapshot().cursor.column }, { 1, 1 })
  Assert.equal(controller:snapshot().cursor.controlId, "upper")
  -- Each repeated home control is stepped over, never stuck on.
  controller:press("right")
  Assert.equal(controller:snapshot().cursor.controlId, "lower")
  controller:press("right")
  Assert.equal(controller:snapshot().cursor.controlId, "symbols")
  controller:press("right")
  Assert.equal(controller:snapshot().cursor.controlId, "back")
  controller:press("right")
  Assert.equal(controller:snapshot().cursor.controlId, "ok")
  controller:press("right")
  Assert.equal(controller:snapshot().cursor.controlId, "upper")
  controller:press("left")
  Assert.equal(controller:snapshot().cursor.controlId, "ok")
  -- Vertical wrap reaches the far glyph row in the same column.
  controller:press("down")
  Assert.deepEqual({ controller:snapshot().cursor.row, controller:snapshot().cursor.column }, { 2, 13 })
  controller:press("down")
  Assert.deepEqual({ controller:snapshot().cursor.row, controller:snapshot().cursor.column }, { 3, 13 })
end

function T.tests.identical_adjacent_glyphs_do_not_trap_horizontal_movement()
  local controller = player()
  controller:press("down")
  controller:press("down")
  Assert.deepEqual({ controller:snapshot().cursor.row, controller:snapshot().cursor.column }, { 4, 1 })
  for _ = 1, 6 do
    controller:press("right")
  end
  Assert.deepEqual({ controller:snapshot().cursor.row, controller:snapshot().cursor.column }, { 4, 7 })
  -- The next cell holds the same blank glyph: retail steps onto it instead
  -- of scanning past every identical cell back to the row start.
  controller:press("right")
  Assert.deepEqual({ controller:snapshot().cursor.row, controller:snapshot().cursor.column }, { 4, 8 })
end

function T.tests.keyboard_text_rows_keep_the_retail_row_formula()
  local FieldUiAssets = require("romdump.src.config.FieldUiAssets")
  local naming = assert(FieldUiAssets.namingScreen, "the field-UI source config publishes naming geometry")
  local window = assert(naming.keyboardWindow, "the keyboard text geometry derives from the window record")
  local originX = naming.pagePlacement.x + window.x
  local originY = window.y + window.textInsetY
  Assert.equal(originX, 27, "keyboard text starts at screen x 27")
  Assert.equal(originY, 12, "keyboard text starts 12 pixels inside the keyboard window")
  Assert.equal(window.cellWidth, 16, "keyboard columns step 16 pixels")
  Assert.equal(window.rowHeight, 19, "keyboard rows keep the 19-pixel source step")
  local localRows = {}
  for row = 1, 5 do
    localRows[row] = 19 * (row - 1) + 4
  end
  Assert.deepEqual(localRows, { 4, 23, 42, 61, 80 }, "local keyboard rows follow 19 * i + 4")
  local composed = {}
  for row = 1, 5 do
    composed[row] = 80 + originY + (row - 1) * window.rowHeight
  end
  Assert.deepEqual(composed, { 92, 111, 130, 149, 168 }, "composed rows add the page/window transform")
end

function T.tests.direct_text_input_ignores_the_keyboard_path()
  local controller = player()
  Assert.isTrue(controller:inputText("AB"))
  Assert.equal(controller:text(), "AB")
  Assert.deepEqual({ controller:snapshot().cursor.row, controller:snapshot().cursor.column }, { 2, 1 })
end

return T
