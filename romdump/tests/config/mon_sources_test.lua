-- Producer-side source inventory contract: the mon compilers resolve every
-- selection they need through MonSources, and the selection functions
-- reproduce the pinned decomp behavior for representative identities. Pure
-- data and pure functions; no I/O and no runtime imports.

local Assert = require("tests.support.Assert")

local T = {}

local function sources()
  return require("romdump.src.config.MonSources")
end

function T.semantic_keys_cover_the_native_identities()
  local MonSources = sources()
  Assert.equal(MonSources.speciesKeys[0], "NONE")
  Assert.equal(MonSources.speciesKeys[152], "CHIKORITA")
  Assert.equal(MonSources.speciesKeys[493], "ARCEUS")
  Assert.equal(MonSources.speciesId("CHIKORITA"), 152)
  Assert.equal(MonSources.moveKeys[33], "TACKLE")
  Assert.equal(MonSources.abilityKeys[65], "OVERGROW")
  Assert.equal(MonSources.itemKeys[83], "THUNDERSTONE")
  Assert.equal(MonSources.typeKeys[12], "grass")
  Assert.equal(MonSources.eggGroupKeys[1], "monster")
  Assert.equal(MonSources.growthKeys[3], "medium_slow")
  Assert.equal(MonSources.evolutionMethods[4], "level")
  Assert.equal(MonSources.damageCategories[0], "physical")
  Assert.equal(MonSources.machineMoves[0].move, "FOCUS_PUNCH")
  Assert.equal(MonSources.messageBanks.species, 237)
  Assert.equal(MonSources.messageBanks.moveName, 750)
  Assert.equal(MonSources.messageBanks.abilityName, 720)
end

function T.form_clamp_and_personal_resolution_follow_the_source()
  local MonSources = sources()
  Assert.equal(MonSources.clampForm(201, 27), 27)
  Assert.equal(MonSources.clampForm(201, 28), 0)
  Assert.equal(MonSources.clampForm(386, 3), 3)
  Assert.equal(MonSources.clampForm(386, 4), 0)
  Assert.equal(MonSources.clampForm(25, 7), 7)
  Assert.equal(MonSources.resolvePersonalMember(152, 0), 152)
  Assert.equal(MonSources.resolvePersonalMember(386, 0), 386)
  Assert.equal(MonSources.resolvePersonalMember(386, 1), 496)
  Assert.equal(MonSources.resolvePersonalMember(413, 2), 500)
  Assert.equal(MonSources.resolvePersonalMember(479, 5), 507)
end

function T.icon_selection_matches_the_source_lookup()
  local MonSources = sources()
  Assert.equal(MonSources.iconNaix(152, false, 0), 159)
  Assert.equal(MonSources.iconNaix(25, true, 0), 501)
  Assert.equal(MonSources.iconNaix(490, true, 0), 502)
  Assert.equal(MonSources.iconNaix(201, false, 1), 507)
  Assert.equal(MonSources.iconNaix(201, false, 27), 533)
  Assert.equal(MonSources.iconNaix(479, false, 5), 546)
end

function T.portrait_selection_matches_the_source_lookup()
  local MonSources = sources()
  local male = MonSources.portraitIds(152, "male", 2, false, 0)
  Assert.equal(male.narc, "pokemon_graphics")
  Assert.equal(male.charMemberId, 152 * 6 + 3)
  Assert.equal(male.palMemberId, 152 * 6 + 4)
  local female = MonSources.portraitIds(152, "female", 2, false, 0)
  Assert.equal(female.charMemberId, 152 * 6 + 2)
  local shiny = MonSources.portraitIds(152, "male", 2, true, 0)
  Assert.equal(shiny.palMemberId, 152 * 6 + 5)
  local deoxys = MonSources.portraitIds(386, "male", 2, false, 1)
  Assert.equal(deoxys.narc, "pokemon_graphics_other")
  Assert.equal(deoxys.charMemberId, 1 + 2)
end

function T.follower_selection_matches_the_source_lookup()
  local MonSources = sources()
  Assert.equal(MonSources.followerSpriteId(1, 0, false), 428)
  Assert.equal(MonSources.followerSpriteId(152, 0, false), 581)
  Assert.equal(MonSources.followerSpriteId(0, 0, false), 428)
  Assert.equal(MonSources.followerModelOffset(494), nil)
  Assert.equal(MonSources.followerVisualId(153), 20153)
  local param = MonSources.followerParamIndex(152, 0, false)
  Assert.equal(param, 153)
end

return { tests = T }
