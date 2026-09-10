-- Whole-corpus mon-command reachability and lowering audits: every claim
-- here depends on walking the complete decoded field-script corpus (which
-- opcodes the retail scripts reach, how lowered nodes dispatch, and which
-- reached family nodes stay unsupported). The static catalog and inventory
-- relationships stay in the default tier; these corpus walks run only when
-- the slow tier is selected.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local FieldScripts = require("tests.rom.support.FieldScripts")
local MonScriptCommands = require("romdump.src.reference.hgss.mon_script_commands")
local ScriptCommands = require("romdump.src.reference.hgss.script_commands")

local T = {}

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

function T.supported_entries_carry_widths_timing_and_lowering(romFs)
  local keys = loweringKeys()
  local reached = reachedOpcodes(romFs)
  local problems = {}
  for _, item in ipairs(familyEntries()) do
    if item.entry ~= nil and item.entry.disposition == "supported" then
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

  local archive, memberIrs = FieldScripts.decode(romFs)
  local reached = {}
  FieldScripts.eachScript(archive, memberIrs, function(_, _, _, lowered)
    for _, item in ipairs(lowered.items) do
      if item.op == "unsupported" and type(item.command) == "number" then
        if MonScriptCommands.byOpcode[item.command] ~= nil then
          local tagged = ScriptCommands.byOpcode[item.command]
          if tagged ~= nil and tagged.disposition ~= "deferred" then
            reached[#reached + 1] = tostring(item.command) .. ":" .. CommandCatalog.name(item.command)
          end
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

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
suite.metadata.slow = true
suite.metadata.tags = { "mon", "script", "corpus" }
return suite
