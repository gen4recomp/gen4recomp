-- Pocket-indexed hero animation state for the field bag: which pose and
-- pattern clips the upper pane presents per pocket, advanced on the fixed
-- presentation cadence. Covers pocket selection, clip resolution for all
-- eight pockets, deterministic frame advance, and rejection of unknown
-- pockets. Pure state; mesh acquisition stays with the draw stage.

local Assert = require("tests.support.Assert")
local BagHeroPresenter = require("libs.hgss.src.presentation.BagHeroPresenter")

local T = {}

local POCKETS = { "items", "medicine", "balls", "tmhm", "berries", "mail", "battle_items", "key_items" }

local function manifest()
  local states = {}
  for _, pocket in ipairs(POCKETS) do
    states[#states + 1] =
      { pocket = pocket, pose = "pocket." .. pocket .. ".pose", pattern = "pocket." .. pocket .. ".pattern" }
  end
  return {
    hero = {
      animations = {
        states = states,
        material = { male = "bag.male.material", female = "bag.female.material" },
      },
    },
  }
end

function T.defaults_to_the_first_pocket_state()
  local presenter = BagHeroPresenter.new({ manifest = manifest() })
  local status = presenter:status()
  Assert.equal(status.pocket, "items")
  Assert.equal(status.pose, "pocket.items.pose")
  Assert.equal(status.pattern, "pocket.items.pattern")
  Assert.equal(status.frame, 0)
end

function T.every_pocket_resolves_its_clips_and_restarts_the_frame()
  local presenter = BagHeroPresenter.new({ manifest = manifest() })
  presenter:updateFixed()
  presenter:updateFixed()
  for _, pocket in ipairs(POCKETS) do
    presenter:selectPocket(pocket)
    local status = presenter:status()
    Assert.equal(status.pocket, pocket)
    Assert.equal(status.pose, "pocket." .. pocket .. ".pose")
    Assert.equal(status.pattern, "pocket." .. pocket .. ".pattern")
    Assert.equal(status.frame, 0, "a pocket switch restarts its animation")
  end
end

function T.frames_advance_on_the_fixed_cadence_only()
  local presenter = BagHeroPresenter.new({ manifest = manifest() })
  presenter:selectPocket("balls")
  for _ = 1, 5 do
    presenter:updateFixed()
  end
  Assert.equal(presenter:status().frame, 5, "five fixed ticks advance five frames")
  Assert.equal(presenter:status().pocket, "balls", "advancing never changes the selected state")
end

function T.unknown_pockets_are_programming_errors()
  local presenter = BagHeroPresenter.new({ manifest = manifest() })
  Assert.throws(function()
    presenter:selectPocket("BOGUS_POCKET")
  end)
  Assert.equal(presenter:status().pocket, "items", "a rejected switch leaves the pocket untouched")
end

return { tests = T }
