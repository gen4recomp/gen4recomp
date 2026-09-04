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
local ScriptCommands = require("romdump.src.reference.hgss.script_commands")

local T = {}

-- The authoritative family tags for this feature area. Keyword matching is
-- not used: an opcode belongs to the gate exactly when the reference
-- catalog tags it.
local FAMILY = { mons = true, starter = true, following_mon = true, party_ui = true }

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

local function familyEntries()
  local entries = {}
  for opcode, entry in pairs(ScriptCommands.byOpcode) do
    if FAMILY[entry.feature] then
      entries[#entries + 1] = { opcode = opcode, entry = entry }
    end
  end
  table.sort(entries, function(a, b)
    return a.opcode < b.opcode
  end)
  return entries
end

local function reachedOpcodes(romFs)
  local archive, memberIrs = FieldScripts.decode(romFs)
  local reached = {}
  FieldScripts.eachScript(archive, memberIrs, function(_, _, structured, lowered)
    FieldScripts.eachStep(structured, function(step)
      for _, code in ipairs((step.provenance or {}).opcodes or {}) do
        reached[code] = true
      end
    end)
    for _, item in ipairs(lowered.items) do
      for _, code in ipairs((item.provenance or {}).opcodes or {}) do
        reached[code] = true
      end
    end
  end)
  return reached
end

local function loweringKeys()
  local keys = {}
  for _, module in ipairs({
    "romdump.src.digest.script.lowering.ControlHandlers",
    "romdump.src.digest.script.lowering.FieldHandlers",
    "romdump.src.digest.script.lowering.AudioHandlers",
  }) do
    local registry = require(module)
    for opcode in pairs(registry) do
      keys[opcode] = true
    end
  end
  return keys
end

function T.every_family_entry_carries_exactly_one_disposition()
  local seenFeatures = {}
  local problems = {}
  for _, item in ipairs(familyEntries()) do
    seenFeatures[item.entry.feature] = true
    if item.entry.disposition ~= "supported" and item.entry.disposition ~= "deferred" then
      problems[#problems + 1] = item.opcode .. ":" .. CommandCatalog.name(item.opcode)
    end
  end
  for feature in pairs(FAMILY) do
    Assert.isTrue(seenFeatures[feature] == true, "the gate must see feature " .. feature)
  end
  Assert.equal(#problems, 0, "every family entry carries one disposition: " .. table.concat(problems, ", "))
end

function T.supported_entries_carry_widths_timing_and_lowering(romFs)
  local keys = loweringKeys()
  local reached = reachedOpcodes(romFs)
  local problems = {}
  for _, item in ipairs(familyEntries()) do
    if item.entry.disposition == "supported" then
      -- Zero-operand commands carry no width entries; a present table may
      -- be empty, while a missing table must be compensated by real
      -- decoded bytes in the corpus (the decoder's unknown-opcode path
      -- still feeds the lowering registry, which the reachability check
      -- below proves per opcode).
      local widths = item.entry.widths
      if widths ~= nil then
        local widthCount = 0
        for _ in pairs(widths) do
          widthCount = widthCount + 1
        end
        if widthCount == 0 and reached[item.opcode] ~= true then
          problems[#problems + 1] = item.opcode .. ":empty widths without corpus bytes"
        end
      elseif reached[item.opcode] ~= true then
        problems[#problems + 1] = item.opcode .. ":missing decoder widths and corpus bytes"
      end
      if type(item.entry.classification) ~= "string" then
        problems[#problems + 1] = item.opcode .. ":missing timing classification"
      end
      if keys[item.opcode] ~= true then
        problems[#problems + 1] = item.opcode .. ":missing lowering"
      end
    end
  end
  table.sort(problems)
  Assert.equal(#problems, 0, "every supported entry is decodable, timed, and lowered: " .. table.concat(problems, ", "))
end

function T.deferred_entries_carry_one_category_and_stay_explicit(romFs)
  local problems = {}
  for _, item in ipairs(familyEntries()) do
    if item.entry.disposition == "deferred" then
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

  local archive, memberIrs = FieldScripts.decode(romFs)
  local reached = {}
  FieldScripts.eachScript(archive, memberIrs, function(_, _, _, lowered)
    for _, item in ipairs(lowered.items) do
      if item.op == "unsupported" and type(item.command) == "number" then
        local tagged = ScriptCommands.byOpcode[item.command]
        if tagged ~= nil and FAMILY[tagged.feature] and tagged.disposition ~= "deferred" then
          reached[#reached + 1] = tostring(item.command) .. ":" .. CommandCatalog.name(item.command)
        end
      end
    end
  end)
  table.sort(reached)
  Assert.equal(
    #reached,
    0,
    "every reached unsupported family node is an explicitly deferred command: " .. table.concat(reached, ", ")
  )
end

function T.lowered_scripts_dispatch_no_source_opcode_number(romFs)
  local archive, memberIrs = FieldScripts.decode(romFs)
  local problems = {}
  local function checkItem(item)
    if type(item.op) ~= "string" then
      problems[#problems + 1] = "numeric op " .. tostring(item.op)
    elseif item.op == "unsupported" then
      -- Only the explicit halt keeps its source opcode number so the
      -- runtime fault can attribute the deferred command.
      if type(item.command) ~= "number" then
        problems[#problems + 1] = "unsupported node without its source command"
      end
    elseif type(item.command) == "number" then
      problems[#problems + 1] = tostring(item.op) .. " still dispatches source opcode " .. tostring(item.command)
    end
  end
  FieldScripts.eachScript(archive, memberIrs, function(_, _, structured, lowered)
    FieldScripts.eachStep(structured, checkItem)
    for _, item in ipairs(lowered.items) do
      checkItem(item)
    end
  end)
  table.sort(problems)
  Assert.equal(#problems, 0, "lowered scripts dispatch on semantic names only: " .. table.concat(problems, ", "))
end

function T.default_lab_scripts_contain_no_undispositioned_command(romFs)
  local archive, memberIrs = FieldScripts.decode(romFs)
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
        local tagged = ScriptCommands.byOpcode[code]
        if tagged ~= nil and FAMILY[tagged.feature] and tagged.disposition == nil then
          undispositioned[#undispositioned + 1] = code .. ":" .. CommandCatalog.name(code)
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
