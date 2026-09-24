-- Pokemon naming host reuses the shared controller and responsive interface.

local Assert = require("tests.support.Assert")
local LayoutGeometry = require("libs.ui.src.LayoutGeometry")
local PokemonNamingState = require("game.hgss.src.field.PokemonNamingState")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")

local T = { tests = {} }

local function measurement(width, height)
  return {
    width = width,
    height = height,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      role = "world",
      touch = true,
    }),
    pixelRatio = 1,
    signature = string.format("pokemon-naming:%dx%d", width, height),
  }
end

local function openState()
  local size = { width = 800, height = 600 }
  local state = PokemonNamingState.new({
    charmap = CatalogFixture.CHARMAP,
    measureDisplay = function()
      return measurement(size.width, size.height)
    end,
  })
  state:open({
    initialText = "A",
    currentText = "A",
    maxLength = 10,
    subject = { kind = "pokemon", species = 152, form = 0, iconKey = "CHIKORITA_0" },
  })
  return state, size
end

function T.tests.keyboard_navigation_confirm_and_b_delete_use_the_reusable_controller()
  local state = openState()
  local before = assert(state:status())
  state:handleInput({ { type = "navigate", direction = "right" } })
  local afterNavigation = assert(state:status())
  Assert.equal(afterNavigation.snapshot.cursor.column, before.snapshot.cursor.column + 1)
  state:handleInput({ { type = "confirm" } })
  Assert.equal(state:status().text, "AB")
  state:handleInput({ { type = "cancel" } })
  Assert.equal(state:status().text, "A", "B deletes a glyph instead of cancelling the modal")
  state:dispose()
end

function T.tests.pointer_ok_submits_and_pointer_cancel_has_no_naming_meaning()
  local state = openState()
  state:handleInput({ { type = "pointer_cancel", pointerId = "touch:1" } })
  Assert.isFalse(state:status().done)
  local plan = state:status().presentation
  local layout = plan.content.layout
  local control = layout.controls.ok
  local x, y =
    LayoutGeometry.logicalToHost(plan.panes[1].placement, control.x + control.width / 2, control.y + control.height / 2)
  state:handleInput({ { type = "pointer_down", pointerId = "touch:1", x = x, y = y } })
  Assert.isTrue(state:status().done)
  state:close()
  Assert.isFalse(state:isActive())
end

function T.tests.display_reflow_republishes_and_close_releases_active_session()
  local state, size = openState()
  local before = state:status().presentation.panes[1].placement.frame.width
  size.width, size.height = 1280, 900
  state:updateFixed()
  local after = state:status().presentation.panes[1].placement.frame.width
  Assert.isTrue(after ~= before, "display measurement changes re-resolve the naming pane")
  state:close()
  Assert.isNil(state:status())
end

function T.tests.failed_open_does_not_publish_a_partial_active_state()
  local state = PokemonNamingState.new({
    charmap = CatalogFixture.CHARMAP,
    measureDisplay = function()
      return measurement(800, 600)
    end,
    overrides = { unknown = function() end },
  })
  local ok = pcall(function()
    state:open({
      initialText = "A",
      currentText = "A",
      maxLength = 10,
      subject = { kind = "pokemon", species = 152, form = 0, iconKey = "CHIKORITA_0" },
    })
  end)
  Assert.isFalse(ok, "invalid naming configuration must fail open")
  Assert.isFalse(state:isActive(), "a failed open publishes no controller")
  Assert.isNil(state:status(), "a failed open leaves no active status")
end

return T
