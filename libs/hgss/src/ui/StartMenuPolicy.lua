-- Pure HGSS Start Menu action policy for the implemented normal field
-- context: the canonical action definitions and the progression rules that
-- build the menu's final action list. The facts are the seven unlock values
-- the runtime reads from the event-state flags (the four CheckGot*
-- progression gates plus the three FLAG_GOT_BAG+idx unlocks) as ordinary
-- internal data; each source action separates list presence (the source
-- inhibit masks, StartMenu_GetStartMenuButtonInhibitFlags_Normal,
-- start_menu.c:288-331) from the gameplay unlock gate
-- (FieldSystem_StartMenuActionIsAvailable, start_menu.c:531-556, gates at
-- sys_flags.c:273-289). The actions() API processes every source action in
-- canonical insertion order (present-but-unimplemented actions keep their
-- canonical display positions) and returns source-present entries with
-- source-enablement state, independent of implementation capability. The
-- runtime composes this with implementation capability to set the final
-- enabled state. Pure domain module: no love, no I/O. Source evidence:
-- pret/pokeheartgold@008257708: src/start_menu.c (StartMenu_BuildActionLists,
-- FieldSystem_StartMenuActionIsAvailable) and src/sys_flags.c.

local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")

local StartMenuPolicy = {}

-- The seven unlock facts of the internal snapshot: the four progression
-- gates and the three flag-gated unlocks.
local FACT_FIELDS = {
  "hasPokedex",
  "hasStarter",
  "bagUnlocked",
  "hasPokegear",
  "trainerCardUnlocked",
  "saveUnlocked",
  "optionsUnlocked",
}

-- The canonical actions in build (insertion) order
-- (StartMenu_BuildActionLists, start_menu.c:483-523): RETIRE, 7, POKEDEX,
-- POKEMON, BAG, POKEGEAR, TRAINER_CARD, SAVE, OPTIONS, RUNNING_SHOES, then
-- the unconditional special Pokégear-family entries 9 and 10 at the reserved
-- display positions 7 and 8. `inhibitedBy` is the presence gate (true =
-- unconditionally inhibited, a fact key = inhibited while that fact is
-- false, absent = never inhibited); `unlockedBy` is the availability gate
-- fact key (absent = always available, matching the source's icon-index-100
-- default TRUE). `targetApplication` is the destination application id from
-- FieldApplicationIds (nil when the destination is not an application:
-- RUNNING_SHOES is a controller toggle, RETIRE is a field action, 7 is a
-- removed feature). `actionKind` describes the semantic type: "application",
-- "field_action", "toggle", or "removed".
local ACTIONS = {
  { id = "vanilla.retire", inhibitedBy = true, actionKind = "field_action" },
  { id = "vanilla.special_7", inhibitedBy = true, actionKind = "removed" },
  {
    id = "vanilla.pokedex",
    actionKind = "application",
    targetApplication = FieldApplicationIds.POKEDEX,
    inhibitedBy = "hasPokedex",
    unlockedBy = "hasPokedex",
    displayPosition = 0,
  },
  {
    id = "vanilla.pokemon",
    actionKind = "application",
    targetApplication = FieldApplicationIds.POKEMON,
    inhibitedBy = "hasStarter",
    unlockedBy = "hasStarter",
    displayPosition = 1,
  },
  {
    id = "vanilla.bag",
    actionKind = "application",
    targetApplication = FieldApplicationIds.BAG,
    inhibitedBy = "bagUnlocked",
    unlockedBy = "bagUnlocked",
    displayPosition = 2,
  },
  {
    id = "vanilla.pokegear",
    actionKind = "application",
    targetApplication = FieldApplicationIds.POKEGEAR,
    inhibitedBy = "hasPokegear",
    unlockedBy = "hasPokegear",
    displayPosition = 3,
  },
  {
    id = "vanilla.trainer_card",
    actionKind = "application",
    targetApplication = FieldApplicationIds.TRAINER_CARD,
    unlockedBy = "trainerCardUnlocked",
    displayPosition = 4,
  },
  {
    id = "vanilla.save",
    actionKind = "field_action",
    unlockedBy = "saveUnlocked",
    displayPosition = 5,
  },
  {
    id = "vanilla.options",
    actionKind = "application",
    targetApplication = FieldApplicationIds.OPTIONS,
    unlockedBy = "optionsUnlocked",
    displayPosition = 6,
  },
  { id = "vanilla.running_shoes", actionKind = "toggle" },
  {
    id = "vanilla.special_9",
    actionKind = "application",
    targetApplication = FieldApplicationIds.POKEGEAR,
    displayPosition = 7,
  },
  {
    id = "vanilla.special_10",
    actionKind = "application",
    targetApplication = FieldApplicationIds.POKEGEAR,
    displayPosition = 8,
  },
}

-- Returns all source-present actions with source-enablement state, independent
-- of implementation capability. This is the source-of-truth policy: every action
-- in the source appears in the returned list if present; unlocked/present are
-- separate questions. The runtime composes this with implementation capability
-- to decide the final enabled state. Fresh records per call; the facts are
-- never mutated.
---@param value table<string, unknown> the seven unlock facts (asserted booleans, unknown keys tolerated)
---@return { id: string, actionKind: string, targetApplication: string?, sourceEnabled: boolean, displayPosition: integer }[]
function StartMenuPolicy.actions(value)
  assert(type(value) == "table", "the start menu policy requires the unlock facts")
  for _, field in ipairs(FACT_FIELDS) do
    assert(type(value[field]) == "boolean", "the start menu policy requires boolean unlock facts")
  end
  local actions = {}
  local presentCount = 0
  for _, definition in ipairs(ACTIONS) do
    local inhibitedBy = definition.inhibitedBy
    local present = inhibitedBy == nil or (inhibitedBy ~= true and value[inhibitedBy] == true)
    if present then
      local unlockedBy = definition.unlockedBy
      local sourceEnabled = unlockedBy == nil or value[unlockedBy] == true
      actions[#actions + 1] = {
        id = definition.id,
        actionKind = definition.actionKind,
        targetApplication = definition.targetApplication,
        sourceEnabled = sourceEnabled,
        displayPosition = definition.displayPosition or presentCount,
      }
      presentCount = presentCount + 1
    end
  end
  return actions
end

return StartMenuPolicy
