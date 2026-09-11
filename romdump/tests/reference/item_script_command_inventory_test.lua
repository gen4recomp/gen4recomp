-- Structural coverage for the source-owned Bag/item command membership.
-- The source catalog remains the authoritative execution metadata; these
-- tests deliberately catch an audit that derives membership from catalog
-- tags or that silently absorbs adjacent gameplay systems.

local Assert = require("tests.support.Assert")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local ItemScriptCommands = require("romdump.src.reference.hgss.item_script_commands")
local ScriptCommands = require("romdump.src.reference.hgss.script_commands")

local T = {}

local CATEGORIES = {
  items = true,
  fossil = true,
  mystery_gift = true,
  shop = true,
  phone_gift = true,
  seal = true,
  apricorn = true,
  prize = true,
  field_item_check = true,
}

-- The generic protocol owned here: inventory primitives, item queries, and
-- buffered item text. Anything else in the inventory is a deferred adjacent
-- system, never a second supported family.
local SUPPORTED = {
  [125] = true,
  [126] = true,
  [127] = true,
  [128] = true,
  [129] = true,
  [130] = true,
  [194] = true,
  [195] = true,
  [196] = true,
  [336] = true,
  [669] = true,
  [843] = true,
  [844] = true,
}

-- Deferred adjacent systems the audit documents without owning.
local DEFERRED = {
  [429] = "fossil",
  [432] = "fossil",
  [433] = "fossil",
  [489] = "mystery_gift",
  [275] = "shop",
  [276] = "shop",
  [277] = "shop",
  [278] = "shop",
  [782] = "shop",
  [613] = "phone_gift",
  [614] = "phone_gift",
  [813] = "phone_gift",
  [133] = "seal",
  [134] = "seal",
  [135] = "seal",
  [572] = "seal",
  [580] = "seal",
  [850] = "seal",
  [623] = "apricorn",
  [624] = "apricorn",
  [625] = "apricorn",
  [626] = "apricorn",
  [736] = "apricorn",
  [738] = "apricorn",
  [567] = "prize",
  [651] = "prize",
  [753] = "field_item_check",
}

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

-- Commands that must never appear in the item inventory: mon-owned mail and
-- daycare transfer commands, representative battle commands (battle item use
-- has no field-script opcode), the cutscene command whose name mentions the
-- Bag without touching inventory, and the mon-owned held-item query.
local NEVER_CLAIMED = { 428, 781, 689, 690, 213, 220, 589, 757, 701 }

function T.inventory_shape_is_valid()
  local seen = {}
  local problems = {}
  for index, record in ipairs(ItemScriptCommands.commands) do
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
  for opcode in pairs(SUPPORTED) do
    Assert.isTrue(seen[opcode] == true, "inventory must include opcode " .. opcode)
  end
  for opcode, category in pairs(DEFERRED) do
    Assert.isTrue(seen[opcode] == true, "inventory must document opcode " .. opcode)
    Assert.equal(ItemScriptCommands.byOpcode[opcode].category, category)
  end
  local count = 0
  for _ in pairs(seen) do
    count = count + 1
  end
  Assert.equal(count, 13 + 27, "the inventory holds exactly the owned protocol plus documented neighbors")
  table.sort(problems)
  Assert.equal(#problems, 0, "inventory rows are unique and classified: " .. table.concat(problems, ", "))
end

function T.supported_rows_are_exactly_the_generic_protocol()
  local problems = {}
  for _, record in ipairs(ItemScriptCommands.commands) do
    if record.category == "items" and SUPPORTED[record.opcode] ~= true then
      problems[#problems + 1] = tostring(record.opcode) .. ":unexpected supported member"
    end
  end
  table.sort(problems)
  Assert.equal(#problems, 0, "no adjacent system rides the supported category: " .. table.concat(problems, ", "))
end

function T.every_inventory_member_has_explicit_disposition()
  local problems = {}
  for _, inventory in ipairs(ItemScriptCommands.commands) do
    local entry = ScriptCommands.byOpcode[inventory.opcode]
    if entry == nil then
      problems[#problems + 1] = tostring(inventory.opcode) .. ":missing catalog entry"
    elseif entry.disposition ~= "supported" and entry.disposition ~= "deferred" then
      problems[#problems + 1] = tostring(inventory.opcode) .. ":missing disposition"
    elseif inventory.category == "items" then
      if entry.disposition ~= "supported" or entry.feature ~= "items" then
        problems[#problems + 1] = tostring(inventory.opcode) .. ":owned command is not marked supported items"
      end
      if entry.classification ~= "continue_same_tick" then
        problems[#problems + 1] = tostring(inventory.opcode) .. ":owned command lacks same-tick timing"
      end
    elseif entry.disposition ~= "deferred" then
      problems[#problems + 1] = tostring(inventory.opcode) .. ":neighbor is not deferred"
    elseif ALLOWED_DEFERRALS[entry.deferredReason] ~= true then
      problems[#problems + 1] = tostring(inventory.opcode) .. ":unexpected deferral category"
    elseif type(entry.deferredNote) ~= "string" or entry.deferredNote == "" then
      problems[#problems + 1] = tostring(inventory.opcode) .. ":missing deferral reason note"
    end
  end
  table.sort(problems)
  Assert.equal(#problems, 0, "every inventoried command carries its disposition: " .. table.concat(problems, ", "))
end

function T.adjacent_systems_are_not_claimed()
  local problems = {}
  for _, opcode in ipairs(NEVER_CLAIMED) do
    if ItemScriptCommands.byOpcode[opcode] ~= nil then
      problems[#problems + 1] = tostring(opcode) .. ":" .. CommandCatalog.name(opcode)
    end
  end
  table.sort(problems)
  Assert.equal(#problems, 0, "adjacent commands stay outside the item inventory: " .. table.concat(problems, ", "))
  for _, opcode in ipairs({ 428, 781, 689, 690 }) do
    local tagged = assert(ScriptCommands.byOpcode[opcode], "the catalog names opcode " .. opcode)
    Assert.equal(tagged.disposition, "deferred", "opcode " .. opcode .. " stays deferred under its owner")
  end
  local heldItem = assert(ScriptCommands.byOpcode[701])
  Assert.equal(heldItem.disposition, "supported", "the held-item query stays supported under its owner")
  Assert.equal(heldItem.feature, "mons", "the held-item query stays in the mon family")
end

function T.inventory_membership_is_independent_of_feature_metadata()
  local inventory = {
    [125] = { opcode = 125, category = "items" },
    [275] = { opcode = 275, category = "shop" },
  }
  local catalog = {
    [125] = { feature = nil, disposition = "supported" },
    [275] = { feature = nil, disposition = "deferred" },
  }
  local joined = {}
  for opcode, record in pairs(inventory) do
    joined[opcode] = { inventory = record, catalog = catalog[opcode] }
  end
  Assert.notNil(joined[125], "a featureless inventoried command remains in the membership join")
  Assert.equal(joined[125].catalog.disposition, "supported", "disposition is read after membership is established")
  Assert.equal(joined[275].catalog.disposition, "deferred", "a deferred neighbor remains joined independently")
end

return { tests = T }
