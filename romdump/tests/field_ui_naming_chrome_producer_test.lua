-- The field-UI producer owns the normal naming source selection: the naming
-- archive alias plus the palette, character bank, base screen, and the three
-- normal page screens. The normal player/Pokemon path uses exactly those
-- members; the special numpad page and the unmapped archive members stay
-- outside this contract.

local Assert = require("tests.support.Assert")
local FieldUiAssets = require("romdump.src.config.FieldUiAssets")

local T = {}

local function selection()
  local config = assert(FieldUiAssets.namingScreen, "the field-UI producer must select normal naming chrome")
  return config
end

function T.normal_naming_source_selection_is_producer_owned()
  local config = selection()
  Assert.isTrue(type(config.alias) == "string" and config.alias ~= "", "the naming archive alias is required")
  Assert.equal(config.paletteMember, 0, "the naming palette member is the main BG palette")
  Assert.equal(config.charMember, 2, "the naming character bank member is fixed")
  Assert.equal(config.baseScreenMember, 4, "the normal naming base is the full 256x192 member")
end

function T.normal_pages_map_to_upper_lower_symbols()
  local config = selection()
  Assert.isTrue(type(config.pageScreenMembers) == "table", "the normal page mapping is required")
  Assert.equal(config.pageScreenMembers.upper, 6, "the Upper page is the first normal keyboard member")
  Assert.equal(config.pageScreenMembers.lower, 7, "the Lower page is the second normal keyboard member")
  Assert.equal(config.pageScreenMembers.symbols, 8, "the Symbols page is the third normal keyboard member")
end

function T.final_page_control_and_keyboard_geometry_match_source_transforms()
  local config = selection()
  Assert.deepEqual(config.pagePlacement, { x = 11, y = 80, width = 256, height = 112 }, "pagePlacement")
  Assert.deepEqual(config.objAnchors.upper, { x = 26, y = 68 }, "objAnchors.upper")
  Assert.deepEqual(config.objAnchors.lower, { x = 58, y = 68 }, "objAnchors.lower")
  Assert.deepEqual(config.objAnchors.symbols, { x = 90, y = 68 }, "objAnchors.symbols")
  Assert.deepEqual(config.objAnchors.back, { x = 158, y = 68 }, "objAnchors.back")
  Assert.deepEqual(config.objAnchors.ok, { x = 198, y = 68 }, "objAnchors.ok")
  Assert.deepEqual(config.objAnchors.backing, { x = 22, y = 56 }, "objAnchors.backing")
  Assert.deepEqual(config.objAnchors.subject, { x = 24, y = 8 }, "objAnchors.subject")
  Assert.equal(config.keyboardText.originX, 27, "keyboardText.originX")
  Assert.equal(config.keyboardText.originY, 12, "keyboardText.originY")
  Assert.equal(config.keyboardText.stepX, 16, "keyboardText.stepX")
  Assert.equal(config.keyboardText.stepY, 19, "keyboardText.stepY")
end

function T.special_and_unmapped_members_stay_outside_normal_naming()
  local config = selection()
  local seen = {}
  seen[config.paletteMember] = true
  seen[config.charMember] = true
  seen[config.baseScreenMember] = true
  for _, member in pairs(config.pageScreenMembers) do
    seen[member] = true
  end
  for _, excluded in ipairs({ 5, 9, 17, 18 }) do
    Assert.isNil(seen[excluded], "member " .. excluded .. " is not part of the normal naming path")
  end
  local count = 0
  for _ in pairs(config.pageScreenMembers) do
    count = count + 1
  end
  Assert.equal(count, 3, "normal naming carries exactly three page members")
end

return { tests = T }
