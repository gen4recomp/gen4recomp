-- ROM-gated follower-command disposition audit: every source opcode in
-- the follower family (595-609, 698, 729) carries a machine-checked
-- disposition, and the core active-follower operations the delivered
-- controller owns are supported rather than deferred. Static catalog
-- assertions pin the contract; the corpus walk proves no reached follower
-- command escapes the catalog.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local FieldScripts = require("tests.rom.support.FieldScripts")
local RomSuite = require("tests.rom.support.RomSuite")
local ScriptCommands = require("romdump.src.reference.hgss.script_commands")

local T = {}

-- The required core: queries, face/pause/wait/movement, the Elm
-- follow-up state operation, the nonblocking transition, settle, and the
-- event-trigger check.
local REQUIRED_SUPPORTED = { 596, 601, 602, 603, 604, 605, 608, 609, 698, 729 }

-- Opaque neighbours that recipe-tracing must still classify explicitly;
-- they may stay deferred only under a documented allowed reason.
local EXPLICIT_ONLY = { 595, 597, 598, 599, 600, 606, 607 }

local function disposition(opcode)
  local entry = ScriptCommands.byOpcode[opcode]
  return entry ~= nil and entry.disposition or nil
end

T["follower pause and wait commands are supported"] = function()
  Assert.equal(disposition(602), "supported", "ToggleFollowingPokemonMovement must pause through the controller")
  Assert.equal(disposition(603), "supported", "WaitFollowingPokemonMovement must wait on controller settlement")
end

T["follower state queries are supported"] = function()
  Assert.equal(disposition(596), "supported", "the partner-state query must read controller state")
  Assert.equal(disposition(729), "supported", "the active-state query must read controller state, not a constant")
end

T["follower settle command is supported"] = function()
  Assert.equal(disposition(609), "supported", "the settle/update check must run controller semantics")
end

T["follower transition command is supported and same-tick"] = function()
  Assert.equal(disposition(608), "supported", "the transition must start through the transition owner")
  Assert.equal(
    CommandCatalog.classification(608),
    CommandCatalog.CONTINUE,
    "the transition must continue in the same tick without a wait task"
  )
end

T["follower family has complete dispositions"] = function(romFs)
  local gaps = {}
  for _, opcode in ipairs(REQUIRED_SUPPORTED) do
    if disposition(opcode) ~= "supported" then
      gaps[#gaps + 1] = opcode .. ":" .. CommandCatalog.name(opcode)
    end
  end
  for _, opcode in ipairs(EXPLICIT_ONLY) do
    local current = disposition(opcode)
    if current ~= "supported" and current ~= "deferred" then
      gaps[#gaps + 1] = opcode .. ":" .. CommandCatalog.name(opcode) .. ":undispositioned"
    end
  end
  table.sort(gaps)
  Assert.equal(#gaps, 0, "every follower-family command is decided: " .. table.concat(gaps, ", "))

  local reached = {}
  local archive, memberIrs = FieldScripts.decode(romFs)
  FieldScripts.eachScript(archive, memberIrs, function(_, _, structured, lowered)
    for _, item in ipairs(structured) do
      FieldScripts.eachStep({ item }, function(step)
        for _, opcode in ipairs((step.provenance or {}).opcodes or {}) do
          reached[opcode] = true
        end
      end)
    end
    for _, item in ipairs(lowered.items) do
      for _, opcode in ipairs((item.provenance or {}).opcodes or {}) do
        reached[opcode] = true
      end
    end
  end)
  local escaping = {}
  local family = {}
  for _, opcode in ipairs(REQUIRED_SUPPORTED) do
    family[opcode] = true
  end
  for _, opcode in ipairs(EXPLICIT_ONLY) do
    family[opcode] = true
  end
  for opcode in pairs(reached) do
    if family[opcode] and disposition(opcode) ~= "supported" and disposition(opcode) ~= "deferred" then
      escaping[#escaping + 1] = opcode .. ":" .. CommandCatalog.name(opcode)
    end
  end
  table.sort(escaping)
  Assert.equal(
    #escaping,
    0,
    "no reached follower command escapes the machine-checked catalog: " .. table.concat(escaping, ", ")
  )
end

return RomSuite.fromFacts(T)
