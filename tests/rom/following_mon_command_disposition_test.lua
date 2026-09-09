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

T["follower movement-mode command is supported and same-tick"] = function()
  Assert.equal(disposition(604), "supported", "the movement-mode setter must stay supported")
  Assert.equal(
    CommandCatalog.classification(604),
    CommandCatalog.CONTINUE,
    "the movement-mode setter must continue in the same tick without a wait task"
  )
end

local FOLLOWER_MODES = { follow_player = true, follow_transition_a = true, follow_transition_b = true }

-- Elm's starter tail (member 843 script 12) drives FollowingPokemonMovement
-- 55 before its scripted walk and restores 48 afterwards: both must lower
-- to semantic movement modes, never to the unrelated movement-script jumps
-- the old namespace decoded them to.
T["elm starter script carries semantic movement modes without jumps"] = function(romFs)
  local archive, memberIrs = FieldScripts.decode(romFs)
  assert(archive:memberCount() > 843, "the script archive must still carry member 843")
  local ir = assert(memberIrs[843], "member 843 must decode")
  local script = assert(ir.scripts[12], "member 843 must still carry the starter script")
  local stdCatalog = require("romdump.src.digest.script.SourceCatalog").catalog()
  local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
  local lowered = SemanticLowering.lowerScript(script, ir, { stdCatalog = stdCatalog })
  local modes = {}
  for _, item in ipairs(lowered.items) do
    Assert.isTrue(item.op ~= "follower_start_movement", "the one-shot movement operation must be gone")
    for _, opcode in ipairs((item.provenance or {}).opcodes or {}) do
      if opcode == 604 then
        Assert.equal(item.op, "follower_set_movement_type", "604 must lower to the persistent mode setter")
        Assert.isTrue(FOLLOWER_MODES[item.movementType] == true, "604 must keep a semantic follower mode")
        Assert.isNil(item.movement, "a movement mode carries no decoded movement action")
        Assert.isNil(item.action, "a movement mode is state, not a movement task")
        Assert.isNil(item.direction, "a movement mode carries no direction")
        Assert.isNil(item.distance, "a movement mode carries no jump distance")
        Assert.isNil(item.speed, "a movement mode carries no speed")
        modes[#modes + 1] = item.movementType
      end
    end
  end
  table.sort(modes)
  Assert.deepEqual(modes, { "follow_player", "follow_transition_a" }, "Elm's tail must set and restore its modes")
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

T["follower transition command is supported and same-tick"] = function()
  Assert.equal(disposition(608), "supported", "the transition must start through the transition owner")
  Assert.equal(
    CommandCatalog.classification(608),
    CommandCatalog.CONTINUE,
    "the transition must continue in the same tick without a wait task"
  )
end

-- Route 24's Rocket cutscene (member 215 script 2) drives
-- FollowingPokemonMovement 56 around its fast east player step and restores
-- 48 afterwards: both must lower to semantic movement modes, and the player
-- step inside the transition must keep its fast semantic pace.
T["route 24 script carries the mode56 transition context with a fast player step"] = function(romFs)
  local archive, memberIrs = FieldScripts.decode(romFs)
  assert(archive:memberCount() > 215, "the script archive must still carry member 215")
  local ir = assert(memberIrs[215], "member 215 must decode")
  local script = assert(ir.scripts[2], "member 215 must still carry the Rocket script")
  local stdCatalog = require("romdump.src.digest.script.SourceCatalog").catalog()
  local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
  local lowered = SemanticLowering.lowerScript(script, ir, { stdCatalog = stdCatalog })
  local modes = {}
  local playerSteps = {}
  for _, item in ipairs(lowered.items) do
    for _, opcode in ipairs((item.provenance or {}).opcodes or {}) do
      if opcode == 604 then
        Assert.equal(item.op, "follower_set_movement_type", "604 must lower to the persistent mode setter")
        Assert.isTrue(FOLLOWER_MODES[item.movementType] == true, "604 must keep a semantic follower mode")
        modes[#modes + 1] = item.movementType
      end
    end
    if item.op == "apply_movement" and item.actor ~= nil and item.actor.special == "player" then
      for _, action in ipairs(item.movement or {}) do
        if action.action == "walk" then
          playerSteps[#playerSteps + 1] = action.direction .. ":" .. tostring(action.speed)
        end
      end
    end
  end
  table.sort(modes)
  Assert.deepEqual(modes, { "follow_player", "follow_transition_b" }, "Route 24 must set and restore its modes")
  local hasFastEast = false
  for _, step in ipairs(playerSteps) do
    if step == "east:fast" then
      hasFastEast = true
    end
  end
  Assert.isTrue(
    hasFastEast,
    "Route 24 must carry its fast east player step inside the transition, saw " .. table.concat(playerSteps, ", ")
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
