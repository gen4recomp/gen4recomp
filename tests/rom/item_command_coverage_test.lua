-- ROM-gated disposition gate for the generic Bag/item script protocol:
-- every audited command carries its catalog disposition, every supported
-- entry is decodable, timed, and lowered, deferred neighbors stay explicit,
-- lowered item nodes dispatch on semantic names only, and the representative
-- Lake of Rage item-ball routine lowers with no unsupported Bag/item node.
-- ROM-gated; asserts relationships between the reference audit, the
-- lowering registries, and the decoded corpus, never commercial data.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local FieldScripts = require("tests.rom.support.FieldScripts")
local RomSuite = require("tests.rom.support.RomSuite")
local ItemScriptCommands = require("romdump.src.reference.hgss.item_script_commands")
local ScriptCommands = require("romdump.src.reference.hgss.script_commands")

local T = {}

-- The only deferral categories the item audit allows. A new category is a
-- deliberate design decision, so it must update this list explicitly.
local ALLOWED_DEFERRALS = {
  item_flow = true,
  mystery_gift = true,
  shop = true,
  phone_gift = true,
  seal = true,
  apricorn = true,
  prize = true,
  field_item_check = true,
}

-- The Lake of Rage shore item-ball routine behind the item acceptance
-- scenario: scr_seq member 938, script index 16. Its unsupported nodes must
-- be exactly none of the Bag/item family.
local BALL_MEMBER = 938
local BALL_SCRIPT = 16

local function familyEntries()
  local entries = {}
  for _, inventory in ipairs(ItemScriptCommands.commands) do
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

function T.supported_entries_carry_widths_timing_and_lowering(romFs)
  local keys = loweringKeys()
  local reached = reachedOpcodes(romFs)
  local problems = {}
  local supported = 0
  for _, item in ipairs(familyEntries()) do
    if item.entry ~= nil and item.entry.disposition == "supported" then
      supported = supported + 1
      if item.inventory.category ~= "items" then
        problems[#problems + 1] = item.opcode .. ":supported outside the owned category"
      end
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
  Assert.equal(supported, 13, "the supported set is exactly the generic protocol")
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
        if ItemScriptCommands.byOpcode[item.command] ~= nil then
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

function T.item_nodes_dispatch_no_source_opcode_number(romFs)
  local archive, memberIrs = FieldScripts.decode(romFs)
  local problems = {}
  local seen = {}
  local function checkItem(item)
    if item.op == "unsupported" then
      return
    end
    if type(item.command) == "number" and ItemScriptCommands.byOpcode[item.command] ~= nil then
      problems[#problems + 1] = tostring(item.op) .. " still dispatches source opcode " .. tostring(item.command)
    end
    if
      item.op == "bag_add_item"
      or item.op == "bag_take_item"
      or item.op == "bag_has_space"
      or item.op == "bag_has_item"
      or item.op == "item_is_tmhm"
      or item.op == "item_get_pocket"
      or item.op == "bag_get_quantity"
    then
      seen[item.op] = true
      if item.command ~= nil then
        problems[#problems + 1] = tostring(item.op) .. " carries a source opcode number"
      end
    end
  end
  FieldScripts.eachScript(archive, memberIrs, function(_, _, structured, lowered)
    FieldScripts.eachStep(structured, checkItem)
    for _, item in ipairs(lowered.items) do
      checkItem(item)
    end
  end)
  table.sort(problems)
  Assert.equal(#problems, 0, "item nodes dispatch on semantic names only: " .. table.concat(problems, ", "))
  for _, op in ipairs({ "bag_add_item", "bag_has_space", "item_get_pocket" }) do
    Assert.isTrue(seen[op] == true, "the corpus reaches semantic operation " .. op)
  end
end

function T.representative_grant_routine_lowers_without_unsupported_item_nodes(romFs)
  local archive, memberIrs = FieldScripts.decode(romFs)
  local found = false
  local stale = {}
  local ops = {}
  local hideResolvesToTrigger = false
  FieldScripts.eachScript(archive, memberIrs, function(member, index, structured, lowered)
    if member == BALL_MEMBER and index == BALL_SCRIPT then
      found = true
      local function checkItem(item)
        if item.op == "unsupported" and ItemScriptCommands.byOpcode[item.command] ~= nil then
          stale[#stale + 1] = tostring(item.command) .. ":" .. CommandCatalog.name(item.command)
        end
        if item.op == "bag_add_item" or item.op == "bag_has_space" or item.op == "item_get_pocket" then
          ops[item.op] = true
        end
        if item.op == "hide_object" and item.actor ~= nil and item.actor.special == "last_talked" then
          hideResolvesToTrigger = true
        end
      end
      FieldScripts.eachStep(structured, checkItem)
      for _, item in ipairs(lowered.items) do
        checkItem(item)
      end
    end
  end)
  Assert.isTrue(found, "the corpus must carry the Lake of Rage item-ball routine")
  table.sort(stale)
  Assert.equal(#stale, 0, "the grant routine lowers with no unsupported Bag/item node: " .. table.concat(stale, ", "))
  for _, op in ipairs({ "bag_add_item", "bag_has_space", "item_get_pocket" }) do
    Assert.isTrue(ops[op] == true, "the grant routine lowers semantic operation " .. op)
  end
  Assert.isTrue(hideResolvesToTrigger, "the grant routine hides the trigger actor through the last-talked special")
end

return RomSuite.fromFacts(T)
