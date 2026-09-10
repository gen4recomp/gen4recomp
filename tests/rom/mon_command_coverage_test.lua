-- Machine-checked disposition gate for every source mon/party/starter/
-- follower command: exactly-once tagging, decoder widths, timing
-- classification, lowering coverage, single-category deferrals, string-op
-- dispatch after lowering, and containment for the default Elm lab scripts.
-- ROM-gated; asserts relationships between the reference catalog, the
-- lowering registries, and the decoded corpus, never commercial data.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local FieldScripts = require("tests.rom.support.FieldScripts")
local RomSuite = require("tests.rom.support.RomSuite")
local MonScriptCommands = require("romdump.src.reference.hgss.mon_script_commands")
local ScriptCommands = require("romdump.src.reference.hgss.script_commands")

local T = {}

-- These are compatibility mappings, not a second category authority. An
-- untagged catalog member is intentionally accepted; inventory shape owns the
-- closed category set.
local ALLOWED_CATALOG_FEATURES = {
  mon = { mons = true },
  party = { mons = true },
  -- Starter scripts also use the shared mon catalog family for source
  -- commands that only buffer or query starter species.
  starter = { starter = true, mons = true },
  party_ui = { party_ui = true },
  following_mon = { following_mon = true },
  pokedex = { mons = true },
  daycare = { mons = true },
  trade = { mons = true },
  mail = { mons = true },
  contest = { mons = true },
  cry = { audio = true },
  special_event = { mons = true },
}

-- The only deferral categories the supported command set allows. A new category is
-- a deliberate design decision, so it must update this list explicitly.
local ALLOWED_DEFERRALS = {
  battle = true,
  egg_daycare = true,
  mail = true,
  trade = true,
  item_flow = true,
  pc_storage = true,
  pokedex = true,
  party_special_application = true,
  contest_ribbon_application = true,
  special_follower_event = true,
}

-- Elm lab script sequence members: the Elm dispatcher, the lab entry
-- welcome, and the starter choice. Production reaches them in that order on
-- the default first visit (dispatcher and starter identities are the ones
-- the field interaction resolves; the welcome auto-starts on lab entry).
local LAB_MEMBER = 843
local LAB_SCRIPTS = { [0] = "dispatcher", [11] = "welcome", [12] = "starter" }

-- The reviewed commands with their semantic evidence owner. Each row
-- names one behavior fixture that fails if the reviewed wrong behavior
-- returns; disposition or handler presence alone never counts as coverage.
local CONFORMANCE = {
  {
    opcode = 76,
    fixture = "libs.hgss.tests.audio.cry_player_test",
    test = "play_cry_pattern_11_applies_source_pitch",
  },
  {
    opcode = 77,
    fixture = "libs.script.tests.core.audio_runtime_test",
    test = "wait_cry_ignores_unrelated_audio",
  },
  { opcode = 140, fixture = "libs.script.tests.core.mons_retail_queries_test", test = "move_queries_mask_eggs" },
  { opcode = 141, fixture = "libs.script.tests.core.mons_retail_queries_test", test = "move_queries_mask_eggs" },
  {
    opcode = 354,
    fixture = "libs.script.tests.core.mons_retail_queries_test",
    test = "species_queries_mask_eggs_and_use_exact_sentinels",
  },
  {
    opcode = 355,
    fixture = "libs.script.tests.core.mons_retail_queries_test",
    test = "ownership_compares_trainer_identity_with_inverted_polarity",
  },
  {
    opcode = 383,
    fixture = "libs.script.tests.core.mons_retail_friendship_test",
    test = "held_item_percent_applies_after_increments_with_integer_division",
  },
  { opcode = 434, fixture = "libs.script.tests.core.mons_retail_queries_test", test = "level_census_skips_eggs" },
  {
    opcode = 457,
    fixture = "libs.script.tests.core.mons_retail_queries_test",
    test = "nature_lookup_and_search_use_retail_conventions",
  },
  {
    opcode = 458,
    fixture = "libs.script.tests.core.mons_retail_queries_test",
    test = "nature_lookup_and_search_use_retail_conventions",
  },
  {
    opcode = 479,
    fixture = "libs.script.tests.core.mons_retail_aggregation_test",
    test = "ribbon_census_counts_distinct_kinds_once_ignoring_eggs",
  },
  {
    opcode = 497,
    fixture = "libs.script.tests.core.mons_retail_queries_test",
    test = "get_mon_types_returns_current_form_native_ids",
  },
  {
    opcode = 535,
    fixture = "libs.script.tests.core.mons_retail_queries_test",
    test = "mon_get_level_masks_eggs",
  },
  {
    opcode = 584,
    fixture = "libs.script.tests.core.mons_retail_aggregation_test",
    test = "representable_parties_report_no_checksum_failure",
  },
  {
    opcode = 596,
    fixture = "libs.script.tests.core.follower_ops_runtime_test",
    test = "partner_state_reports_source_object_param_nibble",
  },
  {
    opcode = 605,
    fixture = "libs.script.tests.core.follower_ops_runtime_test",
    test = "reposition_operation_places_through_the_controller",
  },
  {
    opcode = 608,
    fixture = "libs.hgss.tests.field.following_mon_transition_controller_test",
    test = "fake_manager_reveals_hidden_captured_partner_at_the_boundary",
  },
  {
    opcode = 632,
    fixture = "libs.script.tests.core.mons_retail_aggregation_test",
    test = "species_zero_enters_duplicate_detection_among_non_eggs",
  },
  {
    opcode = 647,
    fixture = "libs.script.tests.core.mons_retail_queries_test",
    test = "species_queries_mask_eggs_and_use_exact_sentinels",
  },
  {
    opcode = 659,
    fixture = "libs.hgss.tests.mons.hgss_mon_service_test",
    test = "set_mon_form_validates_and_mutates_only_form",
  },
  {
    opcode = 701,
    fixture = "libs.script.tests.core.mons_retail_queries_test",
    test = "mon_has_item_includes_eggs",
  },
  {
    opcode = 621,
    fixture = "romdump.tests.starter_ball_command_lowering_test",
    test = "command_lowers_without_source_opcode_runtime_operands",
  },
  {
    opcode = 828,
    fixture = "libs.script.tests.core.mons_retail_aggregation_test",
    test = "contest_updates_saturate_and_honor_source_no_ops",
  },
}

-- Reverse census evidence: catalog feature tags are secondary signals only.
-- The independent inventory remains the authority; these sets merely require
-- that an established family-tagged catalog entry (or an explicitly
-- source-identified cry opcode, which carries no family tag) has a matching
-- inventory row. Generic audio tags never count as family evidence.
local CATALOG_FAMILY_FEATURES = {
  mons = true,
  starter = true,
  following_mon = true,
  party_ui = true,
}

local CRY_CATALOG_OPCODES = {
  [76] = true,
  [77] = true,
  [89] = true,
  [90] = true,
  [91] = true,
  [92] = true,
}

-- Reverse census auditor: every catalog entry carrying an established
-- family tag, plus every explicitly source-identified cry opcode, must have
-- a matching independent inventory row. Returns missing `{ opcode, name }`
-- records sorted numerically for deterministic diagnostics.
local function requiresInventoryMembership(opcode, entry)
  if CRY_CATALOG_OPCODES[opcode] == true then
    return true
  end
  return CATALOG_FAMILY_FEATURES[entry.feature] == true
end

local function reverseGaps(inventoryByOpcode)
  local gaps = {}
  for opcode, entry in pairs(ScriptCommands.byOpcode) do
    if requiresInventoryMembership(opcode, entry) and inventoryByOpcode[opcode] == nil then
      gaps[#gaps + 1] = { opcode = opcode, name = CommandCatalog.name(opcode) }
    end
  end
  table.sort(gaps, function(a, b)
    return a.opcode < b.opcode
  end)
  return gaps
end

local function cloneLookup(lookup)
  local cloned = {}
  for opcode, record in pairs(lookup) do
    cloned[opcode] = record
  end
  return cloned
end

local function familyEntries()
  local entries = {}
  for _, inventory in ipairs(MonScriptCommands.commands) do
    entries[#entries + 1] = {
      opcode = inventory.opcode,
      inventory = inventory,
      entry = ScriptCommands.byOpcode[inventory.opcode],
    }
  end
  table.sort(entries, function(a, b)
    return a.opcode < b.opcode
  end)
  return entries
end

function T.reviewed_commands_carry_semantic_evidence()
  local problems = {}
  local seen = {}
  local inventory = {}
  for _, item in ipairs(MonScriptCommands.commands) do
    inventory[item.opcode] = item
  end
  for _, row in ipairs(CONFORMANCE) do
    seen[row.opcode] = (seen[row.opcode] or 0) + 1
    local entry = ScriptCommands.byOpcode[row.opcode]
    local source = inventory[row.opcode]
    if source == nil then
      problems[#problems + 1] = row.opcode .. ":missing inventory entry"
    elseif
      entry == nil
      or (source.category == "cry" and CommandCatalog.classification(row.opcode) == CommandCatalog.UNSUPPORTED)
      or (source.category ~= "cry" and entry.disposition ~= "supported")
    then
      problems[#problems + 1] = row.opcode .. ":" .. source.category .. ":not supported"
    else
      local ok, module = pcall(require, row.fixture)
      local suite = ok and (module.tests or module) or nil
      if type(suite) ~= "table" or type(suite[row.test]) ~= "function" then
        problems[#problems + 1] = row.opcode
          .. ":"
          .. source.category
          .. ":"
          .. CommandCatalog.name(row.opcode)
          .. ":missing semantic fixture "
          .. row.fixture
          .. "."
          .. row.test
      end
    end
  end
  for opcode, count in pairs(seen) do
    Assert.equal(count, 1, "reviewed opcode " .. tostring(opcode) .. " appears exactly once")
  end
  local inventoryOnly = 0
  for opcode in pairs(inventory) do
    if seen[opcode] == nil then
      inventoryOnly = inventoryOnly + 1
    end
  end
  Assert.isTrue(inventoryOnly > 0, "the source inventory contains commands outside conformance evidence")
  table.sort(problems)
  Assert.equal(#problems, 0, "every reviewed command links to a behavior fixture: " .. table.concat(problems, ", "))
end

function T.inventory_entries_match_catalog()
  local problems = {}
  for _, item in ipairs(familyEntries()) do
    if item.entry == nil then
      problems[#problems + 1] = item.opcode .. ":" .. item.inventory.category .. ":missing catalog entry"
    else
      local allowed = ALLOWED_CATALOG_FEATURES[item.inventory.category]
      if allowed ~= nil and item.entry.feature ~= nil and allowed[item.entry.feature] ~= true then
        problems[#problems + 1] = item.opcode
          .. ":"
          .. CommandCatalog.name(item.opcode)
          .. ":"
          .. item.inventory.category
          .. ":unexpected catalog feature "
          .. tostring(item.entry.feature)
      end
    end
  end
  table.sort(problems)
  Assert.equal(
    #problems,
    0,
    "every inventoried command joins compatible catalog metadata: " .. table.concat(problems, ", ")
  )
end

function T.catalog_family_evidence_resolves_to_inventory()
  local gaps = reverseGaps(MonScriptCommands.byOpcode)
  local rendered = {}
  for _, gap in ipairs(gaps) do
    rendered[#rendered + 1] = gap.opcode .. ":" .. gap.name
  end
  Assert.equal(
    #gaps,
    0,
    "every family-tagged or explicit-cry catalog command has an inventory row: " .. table.concat(rendered, ", ")
  )
end

function T.removed_family_command_is_reported_as_missing_inventory()
  local mutated = cloneLookup(MonScriptCommands.byOpcode)
  mutated[137] = nil
  local gaps = reverseGaps(mutated)
  Assert.equal(#gaps, 1, "removing one family opcode reports exactly one gap")
  Assert.equal(gaps[1].opcode, 137, "the reported gap is the removed opcode")
  Assert.equal(gaps[1].name, CommandCatalog.name(137), "the gap names the catalog command")
end

function T.removed_cry_command_is_reported_without_generic_audio()
  local mutated = cloneLookup(MonScriptCommands.byOpcode)
  mutated[89] = nil
  local gaps = reverseGaps(mutated)
  Assert.equal(#gaps, 1, "removing one cry opcode reports exactly one gap, not every audio command")
  Assert.equal(gaps[1].opcode, 89, "the reported gap is the removed cry opcode")
  Assert.equal(gaps[1].name, CommandCatalog.name(89), "the gap names the catalog command")
end

function T.every_inventory_entry_carries_exactly_one_disposition()
  local problems = {}
  for _, item in ipairs(familyEntries()) do
    if item.entry == nil then
      problems[#problems + 1] = item.opcode .. ":missing catalog entry"
    else
      if item.entry.disposition ~= "supported" and item.entry.disposition ~= "deferred" then
        problems[#problems + 1] = item.opcode .. ":" .. CommandCatalog.name(item.opcode)
      end
    end
  end
  Assert.equal(#problems, 0, "every inventory entry carries one disposition: " .. table.concat(problems, ", "))
end

function T.deferred_entries_carry_one_category_and_stay_explicit()
  local problems = {}
  for _, item in ipairs(familyEntries()) do
    if item.entry ~= nil and item.entry.disposition == "deferred" then
      if ALLOWED_DEFERRALS[item.entry.deferredReason] ~= true then
        problems[#problems + 1] = item.opcode .. ":unexpected deferral category"
      end
      if type(item.entry.deferredNote) ~= "string" or item.entry.deferredNote == "" then
        problems[#problems + 1] = item.opcode .. ":missing deferral reason note"
      end
    end
  end
  table.sort(problems)
  Assert.equal(#problems, 0, "every deferred entry names one allowed category: " .. table.concat(problems, ", "))
  -- The reachability proof that every reached unsupported family node is an
  -- explicitly deferred command walks the whole corpus and lives in the
  -- slow sibling.
end

function T.default_lab_scripts_contain_no_undispositioned_command(romFs)
  -- Elm Lab containment over the explicitly named lab member only: the
  -- dispatcher, the entry welcome, and the starter choice. The
  -- whole-corpus reachability and lowering audits live in the slow sibling.
  local archive, memberIrs = FieldScripts.decodeMembers(romFs, { LAB_MEMBER })
  assert(archive:memberCount() > LAB_MEMBER, "the script archive must still carry the lab member")
  local found = {}
  local transitions = {}
  local staleHalts = {}
  FieldScripts.eachScript(archive, memberIrs, function(member, index, structured, lowered)
    if member == LAB_MEMBER and LAB_SCRIPTS[index] ~= nil then
      found[index] = true
      local codes = {}
      local seen = {}
      local function note(code)
        if not seen[code] then
          seen[code] = true
          codes[#codes + 1] = code
        end
      end
      FieldScripts.eachStep(structured, function(step)
        for _, code in ipairs((step.provenance or {}).opcodes or {}) do
          note(code)
        end
      end)
      for _, item in ipairs(lowered.items) do
        for _, code in ipairs((item.provenance or {}).opcodes or {}) do
          note(code)
        end
        if item.op == "follower_transition" and index == 12 then
          transitions[#transitions + 1] = item
        end
        if item.op == "unsupported" and item.command == 608 then
          staleHalts[#staleHalts + 1] = index
        end
      end
      local undispositioned = {}
      for _, code in ipairs(codes) do
        if MonScriptCommands.byOpcode[code] ~= nil then
          local tagged = ScriptCommands.byOpcode[code]
          if tagged ~= nil and tagged.disposition == nil then
            undispositioned[#undispositioned + 1] = code .. ":" .. CommandCatalog.name(code)
          end
        end
      end
      table.sort(undispositioned)
      Assert.equal(
        #undispositioned,
        0,
        "lab script " .. index .. " has no undispositioned family command: " .. table.concat(undispositioned, ", ")
      )
    end
  end)
  for index, role in pairs(LAB_SCRIPTS) do
    Assert.isTrue(found[index] == true, "the corpus must carry the lab " .. role .. " script")
  end
  -- The starter script runs the choice, the starter flag, the 605 follow-up
  -- tail, and the pause query, then starts the nonblocking follower
  -- transition and keeps going: the transition lowers to one no-operand
  -- semantic node, never to an explicit unsupported halt.
  Assert.equal(#staleHalts, 0, "no script may still halt on the transition command")
  Assert.equal(#transitions, 1, "exactly the starter script lowers one transition node")
  Assert.isNil(transitions[1].command, "transition semantics dispatch no source opcode number")
end

return RomSuite.fromFacts(T)
