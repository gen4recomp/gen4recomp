-- Production-composed field-menu contracts. A real generated HGSS menu runs
-- through FieldRuntime: one complete selection path and one mid-menu restart.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldState = require("game.hgss.src.field.FieldState")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    derivedAssets = { "map:7" },
    tags = { "field", "menu", "responsive", "topology", "script" },
  },
  tests = {},
}

-- This compact three-choice vanilla menu is a source-faithful 749--752 flow.
-- Its second value is 1, so selection is observably distinct from both the
-- initial row and the source-message id.
local VANILLA_MENU = "vanilla.hgss.scr_seq.0003.script_056"
local RESULT_VARIABLE = 32780

local function withGame(fieldOptions, fn)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
    fieldOptions = fieldOptions,
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- Acceptance owns the non-rendering runtime, while this thin host adapter
-- invokes the same FieldState callbacks that LÖVE dispatches in production.
-- It deliberately has no synthetic input behavior of its own.
local function hostCallbacks(game)
  return setmetatable({
    runtime = {
      input = game.runtime.input,
      actionKeys = game.runtime.actionKeys,
      cancelKeys = game.runtime.cancelKeys,
      menuKeys = game.runtime.menuKeys,
    },
  }, FieldState)
end

local function menuIsModal(snapshot)
  return snapshot.menu ~= nil and snapshot.menu.modal == true
end

local function openVanillaMenu(game)
  game:startScript(VANILLA_MENU)
  return game:advanceUntil("vanilla field menu becomes modal", menuIsModal, 120)
end

local function pressConfirm(game, source)
  game.runtime.input:pressAction(source)
  game:step()
  game.runtime.input:releaseAction(source)
end

local function pressKey(game, state, key)
  state:keypressed(key)
  game:step()
  state:keyreleased(key)
end

local function itemCenter(snapshot, itemIndex)
  local menu = assert(snapshot.menu, "field menu snapshot is required")
  local rect = assert(menu.itemRects[itemIndex], "field menu item rectangle is required")
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

local function selectSecondItem(game)
  local opened = openVanillaMenu(game)
  local state = hostCallbacks(game)
  pressKey(game, state, "s")
  pressConfirm(game, "key:return")
  game:advanceUntil("field menu closes after selection", function(snapshot)
    return snapshot.menu ~= nil and not snapshot.menu.modal
  end, 120)
  return opened
end

-- A real 749--752 menu reaches the script-owned controller and writes the
-- vanilla value, never the visual row number or source message id.
function T.tests.vanilla_menu_selection_commits_its_script_result()
  withGame({}, function(game)
    local opened = selectSecondItem(game)
    local layout = assert(opened.menu.layout, "modal menu must expose production layout")
    Assert.isTrue(layout.surface.touch == false, "default desktop surface must not claim touch capability")
    Assert.equal(game.runtime.scripts.worldState:getVar(RESULT_VARIABLE), 1)
  end)
end

-- Opcode 749 deliberately yields after creating its builder.
-- A process restart at that source-faithful boundary must retain the builder
-- in the foreground script instance, so the later 751/752 operations can
-- publish the same real menu and write its selected HGSS value.
function T.tests.restart_after_hgss_menu_begin_resumes_the_real_menu_builder()
  withGame({}, function(game)
    game:startScript(VANILLA_MENU)
    game:step()

    local resumed = game:restart({ save = "resume" })
    local opened = resumed:advanceUntil("resumed HGSS menu becomes modal", menuIsModal, 120)

    local x, y = itemCenter(opened, 1)
    resumed.runtime.input:pointerDown("mouse:1", x, y)
    resumed:step()
    resumed.runtime.input:pointerUp("mouse:1", x, y)
    resumed:advanceUntil("resumed HGSS menu closes after selection", function(snapshot)
      return snapshot.menu ~= nil and not snapshot.menu.modal
    end, 120)
    Assert.equal(resumed.runtime.scripts.worldState:getVar(RESULT_VARIABLE), 1)
  end)
end

return T
