-- Whole-corpus follower-command audits: the global invariant that no
-- generated script carries a one-shot follower movement, and the
-- reachability proof that no reached follower-family command escapes the
-- machine-checked disposition catalog. Both claims depend on walking the
-- complete decoded field-script corpus. The static disposition checks and
-- the explicit Elm starter and Route 24 retail checks stay in the default
-- tier; these corpus walks run only when the slow tier is selected.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local FieldScripts = require("tests.rom.support.FieldScripts")
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

-- Corpus-wide gate: no lowered script may still carry the one-shot
-- operation, and every 604-derived node must be a semantic mode setter.
T["no generated script carries a one-shot follower movement"] = function(romFs)
  local archive, memberIrs = FieldScripts.decode(romFs)
  local violations = {}
  FieldScripts.eachScript(archive, memberIrs, function(member, index, structured, lowered)
    for _, item in ipairs(lowered.items) do
      if item.op == "follower_start_movement" then
        violations[#violations + 1] = ("member %d script %d: one-shot follower movement"):format(member, index)
      end
      for _, opcode in ipairs((item.provenance or {}).opcodes or {}) do
        if opcode == 604 and item.op ~= "follower_set_movement_type" then
          violations[#violations + 1] = ("member %d script %d: 604 lowers to %s"):format(member, index, item.op)
        end
      end
    end
    FieldScripts.eachStep(structured, function(step)
      if step.op == "follower_start_movement" then
        violations[#violations + 1] = ("member %d script %d: structured one-shot movement"):format(member, index)
      end
    end)
  end)
  table.sort(violations)
  Assert.equal(#violations, 0, "stale follower lowering must not survive: " .. table.concat(violations, ", "))
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

local suite = require("tests.rom.support.RomSuite").fromFacts(T)
suite.metadata.slow = true
suite.metadata.tags = { "following-mon", "script", "corpus" }
return suite
