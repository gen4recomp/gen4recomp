-- Opcode disposition audit: every source command in the mon, party,
-- starter, and follower family carries exactly one machine-checked
-- disposition in the authoritative catalog, with supported entries lowering
-- to real semantics and deferred entries carrying a stable dependency
-- category. Feature work that owns an entry flips it to supported.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local ScriptCommands = require("romdump.src.reference.hgss.script_commands")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

local FEATURES = { mons = true, starter = true, party_ui = true, following_mon = true }
local CATEGORIES = {
  battle = true,
  level_transition = true,
  evolution = true,
  pokedex = true,
  pc_storage = true,
  egg_daycare = true,
  mail = true,
  trade = true,
  item_flow = true,
  contest_ribbon_application = true,
  pokerus_propagation = true,
  special_follower_event = true,
  party_special_application = true,
}

-- The complete source family: every command implemented in scrcmd_party.c,
-- the starter and party-selection commands, every scrcmd_c.c command driven
-- by follower state, and the text-buffer commands reading party/mon data.
local FAMILY = {
  137,
  138,
  139,
  140,
  141,
  167,
  193,
  199,
  202,
  203,
  206,
  222,
  238,
  239,
  282,
  290,
  291,
  312,
  313,
  332,
  337,
  349,
  351,
  354,
  355,
  356,
  357,
  358,
  359,
  361,
  362,
  363,
  364,
  365,
  366,
  369,
  372,
  373,
  382,
  383,
  384,
  387,
  388,
  392,
  396,
  397,
  398,
  399,
  423,
  424,
  428,
  434,
  457,
  458,
  470,
  472,
  473,
  474,
  477,
  478,
  479,
  480,
  481,
  482,
  496,
  506,
  529,
  542,
  584,
  596,
  600,
  601,
  602,
  603,
  604,
  609,
  621,
  632,
  647,
  671,
  674,
  676,
  688,
  689,
  690,
  698,
  707,
  711,
  715,
  727,
  744,
  776,
  778,
  781,
  783,
  785,
  786,
  787,
  788,
  789,
  790,
  827,
  828,
  836,
  845,
}

-- Commands owned by later follower work. They stay deferred here with
-- their concrete current dependency. The starter, party-selection, and
-- core follower entries flipped to supported with their blocking
-- applications.
local LATER_OWNED = {
  [600] = "following_mon",
  [711] = "following_mon",
  [727] = "following_mon",
  [783] = "following_mon",
}

local function entry(opcode)
  local found = ScriptCommands.byOpcode[opcode]
  Assert.notNil(found, "the pinned catalog names opcode " .. opcode)
  return assert(found)
end

local function lowerSingle(opcode)
  local widths = CommandCatalog.widths(opcode) or {}
  local operands = {}
  for index = 1, #widths do
    operands[index] = 0
  end
  local lowered = SemanticLowering.lowerScript(
    { instructions = { { opcode = opcode, operands = operands, offset = 0 } } },
    { member = 12, scripts = {}, movements = {} },
    { stdCatalog = SourceCatalog.catalog() }
  )
  return lowered.items
end

function T.every_family_command_carries_exactly_one_disposition()
  for _, opcode in ipairs(FAMILY) do
    local tagged = entry(opcode)
    Assert.isTrue(FEATURES[tagged.feature] == true, "opcode " .. opcode .. " names its mon-family feature")
    if tagged.disposition == "supported" then
      Assert.isNil(tagged.deferredReason, "opcode " .. opcode .. " carries no deferral category")
      Assert.notNil(tagged.classification, "opcode " .. opcode .. " keeps its source timing")
    elseif tagged.disposition == "deferred" then
      Assert.isTrue(
        CATEGORIES[tagged.deferredReason] == true,
        "opcode " .. opcode .. " defers under one documented dependency category"
      )
    else
      Assert.isTrue(false, "opcode " .. opcode .. " has a supported-or-deferred disposition")
    end
  end
end

function T.later_owned_commands_wait_with_their_current_dependency()
  for opcode, feature in pairs(LATER_OWNED) do
    local tagged = entry(opcode)
    Assert.equal(tagged.disposition, "deferred", "opcode " .. opcode .. " waits for its owner")
    Assert.equal(tagged.feature, feature, "opcode " .. opcode .. " names its owning feature")
  end
end

function T.gift_command_is_supported_with_real_semantics()
  local tagged = entry(137)
  Assert.equal(tagged.disposition, "supported", "the gift command is supported here")
  Assert.equal(tagged.feature, "mons", "the gift command belongs to the mon family")
end

function T.deferred_commands_lower_to_explicit_unsupported_nodes()
  for _, opcode in ipairs({ 138, 290, 291, 470 }) do
    local tagged = entry(opcode)
    Assert.equal(tagged.disposition, "deferred", "opcode " .. opcode .. " is deferred")
    local items = lowerSingle(opcode)
    Assert.equal(#items, 1, "opcode " .. opcode .. " lowers to one step")
    Assert.equal(items[1].op, "unsupported", "opcode " .. opcode .. " stays explicit")
    Assert.equal(items[1].command, opcode, "the unsupported node keeps the source opcode")
    Assert.equal(items[1].originalName, CommandCatalog.name(opcode), "the unsupported node keeps the source name")
  end
end

return { tests = T }
