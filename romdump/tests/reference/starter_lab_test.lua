-- Pinned Elm's Lab starter-ball source facts. The map id, map symbol, model
-- member, and three base translations are retail literals from
-- pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- (ScrCmd_PlaceStarterBallsInElmsLab): each translation is the VecFx32
-- map-prop base translation passed to MapPropManager_LoadOne, already
-- post-map-model-posScale, so the producer normalizes them by tiles only.

local Assert = require("tests.support.Assert")
local StarterLab = require("romdump.src.reference.hgss.starter_lab")

local T = {}

function T.pins_the_elm_starter_source_identity()
  Assert.equal(StarterLab.mapId, 61)
  Assert.equal(StarterLab.mapSymbol, "MAP_NEW_BARK_ELMS_LAB_1F")
  Assert.equal(StarterLab.modelMemberId, 0x8D)
end

function T.pins_the_three_retail_base_translations()
  Assert.equal(#StarterLab.positions, 3)
  local expected = {
    { x = 131, y = 0, z = 65 },
    { x = 141, y = 0, z = 65 },
    { x = 136, y = 0, z = 72 },
  }
  for index, want in ipairs(expected) do
    local got = StarterLab.positions[index]
    Assert.equal(got.x, want.x, "starter position " .. index .. " x")
    Assert.equal(got.y, want.y, "starter position " .. index .. " y")
    Assert.equal(got.z, want.z, "starter position " .. index .. " z")
  end
end

return { tests = T }
