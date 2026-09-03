local Assert = require("tests.support.Assert")
local HgssArchives = require("romdump.src.config.HgssArchives")

local T = {}

function T.resolves_friendly_alias_to_full_entry()
  local e = HgssArchives.resolve("map_matrices")
  Assert.equal(e.symbol, "NARC_fielddata_mapmatrix_map_matrix")
  Assert.equal(e.narcId, 41)
  Assert.equal(e.path, "a/0/4/1")
  Assert.equal(e.alias, "map_matrices")
  Assert.isTrue(e.required)
end

function T.resolves_by_symbol()
  local e = HgssArchives.resolve("NARC_msgdata_msg")
  Assert.equal(e.narcId, 27)
  Assert.equal(e.alias, "messages")
  Assert.isTrue(e.required)
end

function T.field_script_headers_aliases_the_script_sequence_archive()
  local e = HgssArchives.resolve("field_script_headers")
  Assert.equal(e.symbol, "NARC_fielddata_script_scr_seq")
  Assert.equal(e.narcId, 12)
  Assert.equal(e.path, "a/0/1/2")
end

function T.resolves_unaliased_raw_symbol()
  local e = HgssArchives.resolve("NARC_a_0_0_0")
  Assert.isNil(e.alias)
  Assert.equal(e.narcId, 0)
  Assert.equal(e.path, "a/0/0/0")
  Assert.isFalse(e.required)
end

function T.optional_alias_is_not_required()
  Assert.isFalse(HgssArchives.resolve("font").required)
end

function T.version_neutral_encounters_selects_heartgold()
  local e = HgssArchives.resolve("encounters", "heartgold")
  Assert.equal(e.symbol, "NARC_fielddata_encountdata_g_enc_data")
  Assert.equal(e.narcId, 37)
end

function T.version_neutral_encounters_selects_soulsilver()
  local e = HgssArchives.resolve("encounters", "soulsilver")
  Assert.equal(e.symbol, "NARC_fielddata_encountdata_s_enc_data")
  Assert.equal(e.narcId, 136)
end

function T.version_neutral_encounters_requires_a_version()
  Assert.throws(function()
    HgssArchives.resolve("encounters")
  end)
end

function T.rejects_unknown_alias()
  Assert.throws(function()
    HgssArchives.resolve("not_a_real_alias")
  end)
end

function T.resolves_map_asset_aliases()
  local cases = {
    { alias = "area_data", narcId = 42, path = "a/0/4/2" },
    { alias = "map_textures", narcId = 44, path = "a/0/4/4" },
    { alias = "building_textures", narcId = 70, path = "a/0/7/0" },
    { alias = "interior_build_models", narcId = 148, path = "a/1/4/8" },
    { alias = "exterior_build_models", narcId = 40, path = "a/0/4/0" },
    { alias = "exterior_build_anim_list", narcId = 107, path = "a/1/0/7" },
    { alias = "build_anim", narcId = 106, path = "a/1/0/6" },
    { alias = "interior_build_anim_list", narcId = 108, path = "a/1/0/8" },
    { alias = "field_static_models", narcId = 103, path = "a/1/0/3" },
    { alias = "area_build_config", narcId = 43, path = "a/0/4/3" },
    { alias = "field_texture_animations", narcId = 139, path = "a/1/3/9" },
    { alias = "field_area_texture_srt", narcId = 140, path = "a/1/4/0" },
    { alias = "follower_params", narcId = 141, path = "a/1/4/1" },
    { alias = "pokemon_graphics_other", narcId = 114, path = "a/1/1/4" },
  }
  for _, c in ipairs(cases) do
    local e = HgssArchives.resolve(c.alias)
    Assert.equal(e.alias, c.alias)
    Assert.equal(e.narcId, c.narcId)
    Assert.equal(e.path, c.path)
  end
end

function T.alias_list_is_complete_and_deterministic()
  local list = HgssArchives.aliasList()
  Assert.equal(#list, 40)
  -- Sorted ascending by narcId, with deterministic alias ordering for shared roles.
  for i = 2, #list do
    local previous = list[i - 1]
    local current = list[i]
    if previous.narcId == current.narcId then
      Assert.isTrue(previous.alias < current.alias, "shared NARC aliases not deterministic")
    else
      Assert.isTrue(previous.narcId < current.narcId, "aliasList not sorted by narcId")
    end
  end
  for _, e in ipairs(list) do
    Assert.notNil(e.symbol)
    Assert.notNil(e.alias)
    Assert.notNil(e.path)
    Assert.notNil(e.narcId)
  end
end

return { tests = T }
