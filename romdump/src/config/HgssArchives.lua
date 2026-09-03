-- HGSS archive manifest: the curation layer over the frozen NARC reference
-- catalog. It maps friendly aliases to NARC symbols, marks which archives
-- the vertical slice requires, and resolves the version-neutral `encounters`
-- alias against the active game version. Pure Lua; the only
-- dependency is the pure-data catalog.

local catalog = require("romdump.src.reference.hgss.narcs")

local HgssArchives = {}

HgssArchives.schema = 1

HgssArchives.provenance = {
  repo = catalog.source.repo,
  commit = catalog.source.commit,
  sources = {
    "include/filesystem_files_def.h",
    "include/filesystem.h",
    "src/filesystem.c",
  },
}

-- Friendly alias -> decomp symbol. Each symbol has one primary
-- alias; version-neutral aliases are resolved separately below.
local ALIAS_TO_SYMBOL = {
  personal = "NARC_poketool_personal_personal",
  growth_tables = "NARC_poketool_personal_growtbl",
  pokemon_graphics = "NARC_poketool_pokegra_pokegra",
  pokemon_graphics_other = "NARC_poketool_pokegra_otherpoke",
  moves = "NARC_poketool_waza_waza_tbl",
  field_scripts = "NARC_fielddata_script_scr_seq",
  field_script_headers = "NARC_fielddata_script_scr_seq",
  font = "NARC_graphic_font",
  item_data = "NARC_itemtool_itemdata_item_data",
  item_icons = "NARC_itemtool_itemdata_item_icon",
  pokemon_icons = "NARC_poketool_icongra_poke_icon",
  messages = "NARC_msgdata_msg",
  zone_events = "NARC_fielddata_eventdata_zone_event",
  level_up_moves = "NARC_poketool_personal_wotbl",
  evolutions = "NARC_poketool_personal_evo",
  encounters_heartgold = "NARC_fielddata_encountdata_g_enc_data",
  map_matrices = "NARC_fielddata_mapmatrix_map_matrix",
  trainer_data = "NARC_poketool_trainer_trdata",
  trainer_parties = "NARC_poketool_trainer_trpoke",
  land_data = "NARC_fielddata_landdata_land_data",
  field_actor_models = "NARC_data_mmodel_mmodel",
  start_menu = "NARC_a_0_1_4",
  intro = "NARC_demo_intro_intro",
  dialogue_frames = "NARC_a_0_3_8",
  signpost_graphics = "NARC_a_0_3_6",
  trainer_card_graphics = "NARC_a_0_4_9",
  field_static_models = "NARC_a_1_0_3",
  -- Map-asset archives. Symbolic decomp names are not exposed
  -- for these in the pinned catalog, so they resolve through the a/G/D/F path.
  area_data = "NARC_a_0_4_2",
  area_build_config = "NARC_a_0_4_3",
  map_textures = "NARC_a_0_4_4",
  building_textures = "NARC_a_0_7_0",
  interior_build_models = "NARC_a_1_4_8",
  interior_build_anim_list = "NARC_a_1_0_8",
  exterior_build_models = "NARC_a_0_4_0",
  exterior_build_anim_list = "NARC_a_1_0_7",
  build_anim = "NARC_a_1_0_6",
  field_texture_animations = "NARC_a_1_3_9",
  field_area_texture_srt = "NARC_a_1_4_0",
  encounters_soulsilver = "NARC_fielddata_encountdata_s_enc_data",
  follower_params = "NARC_fielddata_tsurepoke_tp_param",
}

local REQUIRED = {
  personal = true,
  moves = true,
  messages = true,
  map_matrices = true,
}

-- Version-neutral aliases pick a concrete alias from the active version.
local VERSION_ALIASES = {
  encounters = { heartgold = "encounters_heartgold", soulsilver = "encounters_soulsilver" },
}

local SYMBOL_TO_ALIAS = {}
for alias, symbol in pairs(ALIAS_TO_SYMBOL) do
  assert(catalog.entries[symbol], "alias " .. alias .. " maps to unknown symbol " .. symbol)
  -- A source archive may have more than one semantic role. Keep the first
  -- alias as the raw-symbol display name while allowing role-specific aliases
  -- such as field_scripts and field_script_headers to share its catalog entry.
  SYMBOL_TO_ALIAS[symbol] = SYMBOL_TO_ALIAS[symbol] or alias
end

local function entryForAlias(alias)
  local symbol = ALIAS_TO_SYMBOL[alias]
  local data = catalog.entries[symbol]
  return {
    symbol = symbol,
    alias = alias,
    narcId = data.narcId,
    path = data.path,
    required = REQUIRED[alias] == true,
  }
end

local function entryForSymbol(symbol)
  local data = catalog.entries[symbol]
  assert(data, "unknown NARC alias or symbol: " .. symbol)
  local alias = SYMBOL_TO_ALIAS[symbol]
  return {
    symbol = symbol,
    alias = alias,
    narcId = data.narcId,
    path = data.path,
    required = alias ~= nil and REQUIRED[alias] == true,
  }
end

-- Resolve a friendly alias, a version-neutral alias, or a raw NARC symbol to a
-- full catalog entry. Version-neutral aliases require an active versionId.
function HgssArchives.resolve(nameOrSymbol, versionId)
  assert(type(nameOrSymbol) == "string", "resolve requires a string")

  local versionMap = VERSION_ALIASES[nameOrSymbol]
  if versionMap then
    assert(versionId, "alias '" .. nameOrSymbol .. "' requires a versionId")
    local alias = versionMap[versionId]
    assert(alias, "no '" .. nameOrSymbol .. "' mapping for version " .. tostring(versionId))
    return entryForAlias(alias)
  end

  if ALIAS_TO_SYMBOL[nameOrSymbol] then
    return entryForAlias(nameOrSymbol)
  end

  return entryForSymbol(nameOrSymbol)
end

-- Every curated entry, ascending by narcId for deterministic iteration.
function HgssArchives.aliasList()
  local list = {}
  for alias in pairs(ALIAS_TO_SYMBOL) do
    list[#list + 1] = entryForAlias(alias)
  end
  table.sort(list, function(a, b)
    if a.narcId ~= b.narcId then
      return a.narcId < b.narcId
    end
    return a.alias < b.alias
  end)
  return list
end

return HgssArchives
