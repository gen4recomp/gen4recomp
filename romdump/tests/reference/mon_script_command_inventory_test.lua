-- Structural coverage for the source-owned mon-adjacent command membership.
-- The source catalog remains the authoritative decoder metadata; these tests
-- deliberately catch an audit that derives membership from catalog tags.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local MonScriptCommands = require("romdump.src.reference.hgss.mon_script_commands")
local ScriptCommands = require("romdump.src.reference.hgss.script_commands")

local T = {}

local CATEGORIES = {
  mon = true,
  party = true,
  starter = true,
  party_ui = true,
  following_mon = true,
  pokedex = true,
  daycare = true,
  trade = true,
  mail = true,
  contest = true,
  cry = true,
  special_event = true,
}

-- These source-audited commands were untagged at the research baseline. The
-- opaque command is identified by its stable source opcode until its retail
-- meaning is represented by the producer inventory.
local EXPECTED_SOURCE_MEMBERS = {
  [497] = "mon",
  [517] = "mon",
  [535] = "mon",
  [659] = "mon",
  [701] = "mon",
}

local function join(inventory, catalog)
  local joined = {}
  for opcode, record in pairs(inventory) do
    joined[opcode] = { inventory = record, catalog = catalog[opcode] }
  end
  return joined
end

function T.inventory_shape_is_valid()
  local seen = {}
  local problems = {}
  for index, record in ipairs(MonScriptCommands.commands) do
    if type(record.opcode) ~= "number" or record.opcode % 1 ~= 0 or record.opcode < 0 then
      problems[#problems + 1] = "row " .. index .. ":invalid opcode"
    elseif seen[record.opcode] then
      problems[#problems + 1] = "duplicate opcode " .. record.opcode
    else
      seen[record.opcode] = true
    end
    if CATEGORIES[record.category] ~= true then
      problems[#problems + 1] = tostring(record.opcode) .. ":invalid category"
    end
  end
  for _, opcode in ipairs({ 76, 77, 497, 535, 596, 608, 659, 701 }) do
    Assert.isTrue(seen[opcode] == true, "inventory must include opcode " .. opcode)
  end
  table.sort(problems)
  Assert.equal(#problems, 0, "inventory rows are unique and classified: " .. table.concat(problems, ", "))
end

function T.source_family_includes_untagged_direct_commands()
  local members = join(MonScriptCommands.byOpcode, ScriptCommands.byOpcode)
  local missing = {}
  for opcode, category in pairs(EXPECTED_SOURCE_MEMBERS) do
    local row = members[opcode]
    if row == nil or row.catalog == nil or row.inventory.category ~= category then
      local name = row and row.catalog and CommandCatalog.name(opcode) or "missing catalog entry"
      missing[#missing + 1] = tostring(opcode) .. ":" .. category .. ":" .. name
    end
  end
  table.sort(missing)
  Assert.equal(
    #missing,
    0,
    "source inventory must expose direct commands independently of catalog feature tags: "
      .. table.concat(missing, ", ")
  )
end

function T.catalog_feature_tag_does_not_remove_an_inventory_member()
  local inventory = {
    [517] = { opcode = 517, category = "mon", sourceMeaning = "opaque source command" },
  }
  local catalog = {
    [517] = { feature = nil },
  }
  local joined = join(inventory, catalog)

  Assert.notNil(joined[517], "an inventoried opcode remains in the joined audit when its catalog feature tag is absent")
end

return { tests = T }
