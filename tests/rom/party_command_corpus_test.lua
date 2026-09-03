-- ROM-gated disposition audit: no source command that touches party,
-- mon, starter, or follower state escapes the machine-checked catalog,
-- even when its opcode name is opaque.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local FieldScripts = require("tests.rom.support.FieldScripts")
local RomSuite = require("tests.rom.support.RomSuite")
local ScriptCommands = require("romdump.src.reference.hgss.script_commands")

local T = {}

local KEYWORDS = {
  "Mon",
  "Party",
  "Starter",
  "Follow",
  "Egg",
  "Daycare",
  "Trade",
  "Mail",
  "Pokedex",
  "Dex",
  "Ribbon",
  "Contest",
  "Friendship",
  "Nature",
  "Pokerus",
}

local function familyByName(opcode)
  local name = CommandCatalog.name(opcode)
  if name:find("Money", 1, true) ~= nil then
    return false
  end
  for _, keyword in ipairs(KEYWORDS) do
    if name:find(keyword, 1, true) ~= nil then
      return true
    end
  end
  return false
end

T["corpus mon-family commands all carry a catalog disposition"] = function(romFs)
  local archive, memberIrs = FieldScripts.decode(romFs)
  local reached = {}
  FieldScripts.eachScript(archive, memberIrs, function(_, _, structured, lowered)
    for _, item in ipairs(structured) do
      FieldScripts.eachStep({ item }, function(step)
        local provenance = step.provenance or {}
        for _, opcode in ipairs(provenance.opcodes or {}) do
          reached[opcode] = true
        end
      end)
    end
    for _, item in ipairs(lowered.items) do
      local provenance = item.provenance or {}
      for _, opcode in ipairs(provenance.opcodes or {}) do
        reached[opcode] = true
      end
    end
  end)
  local untagged = {}
  for opcode in pairs(reached) do
    if familyByName(opcode) then
      local tagged = ScriptCommands.byOpcode[opcode]
      if tagged == nil or (tagged.disposition ~= "supported" and tagged.disposition ~= "deferred") then
        untagged[#untagged + 1] = opcode .. ":" .. CommandCatalog.name(opcode)
      end
    end
  end
  table.sort(untagged)
  Assert.equal(#untagged, 0, "every reached mon-family command is dispositioned: " .. table.concat(untagged, ", "))
end

T["supported mon-family commands never lower to silent fallbacks"] = function(romFs)
  local archive, memberIrs = FieldScripts.decode(romFs)
  local silent = {}
  FieldScripts.eachScript(archive, memberIrs, function(_, _, _, lowered)
    for _, item in ipairs(lowered.items) do
      if item.op == "unsupported" and item.command ~= nil then
        local tagged = ScriptCommands.byOpcode[item.command]
        if tagged ~= nil and tagged.disposition == "supported" then
          silent[#silent + 1] = item.command .. ":" .. CommandCatalog.name(item.command)
        end
      end
    end
  end)
  table.sort(silent)
  Assert.equal(#silent, 0, "supported commands lower to real semantics: " .. table.concat(silent, ", "))
end

return RomSuite.fromFacts(T)
