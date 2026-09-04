-- Disposition audit for the party-screen selection cluster: the selection
-- launch and its result reading are supported through the shared party
-- screen, while every other party-ui command keeps an explicit deferred
-- category. No party-ui command escapes the machine-checked catalog
-- without a disposition.

local Assert = require("tests.support.Assert")
local ScriptCommands = require("romdump.src.reference.hgss.script_commands")

local T = {}

local SUPPORTED_SELECTION_CLUSTER = { [349] = true, [351] = true }

function T.selection_cluster_is_supported_and_party_ui_stays_dispositioned()
  for _, opcode in ipairs({ 349, 351 }) do
    local entry = assert(
      ScriptCommands.byOpcode[opcode],
      "opcode " .. opcode .. " must stay in the machine-checked command catalog"
    )
    Assert.equal(
      entry.disposition,
      "supported",
      "opcode " .. opcode .. " (" .. tostring(entry.name) .. ") must be supported through the party screen"
    )
  end
  local undispositioned = {}
  for opcode, entry in pairs(ScriptCommands.byOpcode) do
    if entry.feature == "party_ui" and not SUPPORTED_SELECTION_CLUSTER[opcode] then
      if entry.disposition ~= "deferred" then
        undispositioned[#undispositioned + 1] = opcode .. ":" .. tostring(entry.name)
      else
        Assert.isTrue(
          entry.deferredReason ~= nil,
          "opcode " .. opcode .. " must name the deferred category that still owns it"
        )
      end
    end
  end
  table.sort(undispositioned)
  Assert.equal(#undispositioned, 0, "non-selection party-ui commands stay explicitly deferred")
end

return { tests = T }
