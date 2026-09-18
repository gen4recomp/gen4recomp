-- The shared HGSS physical A/B/X binding authority covers the field,
-- Oak-hosted naming keys, and Main Menu from one manifest source.

local Assert = require("tests.support.Assert")

local T = { tests = {} }

local BINDINGS_REQUIRE_OK, HgssInputBindings = pcall(require, "game.hgss.src.HgssInputBindings")
local Manifest = require("data.manifests.field_presentation")

local ACTION_ALIASES = { "space", "return", "kpenter" }
local CANCEL_ALIASES = { "backspace", "delete", "escape" }
local MENU_ALIASES = { "tab" }

local function assertExactAliases(actual, expected, what)
  assert(type(actual) == "table", "the manifest publishes " .. what .. " aliases")
  local seen = {}
  for _, key in ipairs(actual) do
    seen[key] = true
  end
  Assert.equal(#actual, #expected, what .. " aliases carry exactly the requested keys")
  for _, key in ipairs(expected) do
    Assert.isTrue(seen[key] == true, what .. " aliases include " .. key)
  end
end

function T.tests.manifest_action_aliases_cover_the_shared_confirm_keys()
  assertExactAliases(Manifest.input and Manifest.input.action, ACTION_ALIASES, "action")
end

function T.tests.manifest_cancel_aliases_cover_the_shared_cancel_keys()
  assertExactAliases(Manifest.input and Manifest.input.cancel, CANCEL_ALIASES, "cancel")
end

function T.tests.manifest_menu_aliases_cover_the_shared_menu_key()
  assertExactAliases(Manifest.input and Manifest.input.menu, MENU_ALIASES, "menu")
end

function T.tests.shared_lookup_resolves_action_cancel_and_menu_without_overlap()
  Assert.isTrue(BINDINGS_REQUIRE_OK, "the shared binding authority exists for field, naming, and menu")
  for _, key in ipairs(ACTION_ALIASES) do
    Assert.isTrue(HgssInputBindings.isActionKey(key), key .. " resolves to action")
    Assert.isFalse(HgssInputBindings.isCancelKey(key), key .. " never resolves to cancel")
    Assert.isFalse(HgssInputBindings.isMenuKey(key), key .. " never resolves to menu")
  end
  for _, key in ipairs(CANCEL_ALIASES) do
    Assert.isTrue(HgssInputBindings.isCancelKey(key), key .. " resolves to cancel")
    Assert.isFalse(HgssInputBindings.isActionKey(key), key .. " never resolves to action")
    Assert.isFalse(HgssInputBindings.isMenuKey(key), key .. " never resolves to menu")
  end
  for _, key in ipairs(MENU_ALIASES) do
    Assert.isTrue(HgssInputBindings.isMenuKey(key), key .. " resolves to menu")
    Assert.isFalse(HgssInputBindings.isActionKey(key), key .. " never resolves to action")
    Assert.isFalse(HgssInputBindings.isCancelKey(key), key .. " never resolves to cancel")
  end
  for _, key in ipairs({ "z", "x", "m" }) do
    Assert.isFalse(HgssInputBindings.isActionKey(key), key .. " stays inert for action")
    Assert.isFalse(HgssInputBindings.isCancelKey(key), key .. " stays inert for cancel")
    Assert.isFalse(HgssInputBindings.isMenuKey(key), key .. " stays inert for menu")
  end
end

function T.tests.menu_copies_stay_independent_of_the_shared_authority()
  Assert.isTrue(BINDINGS_REQUIRE_OK, "the shared binding authority exists for field, naming, and menu")
  local first = HgssInputBindings.menuKeys()
  Assert.isTrue(first["tab"] == true, "the menu copy carries the menu key")
  first["tab"] = nil
  first["m"] = true
  Assert.isTrue(HgssInputBindings.isMenuKey("tab"), "mutating a copy never changes the authority")
  Assert.isFalse(HgssInputBindings.isMenuKey("m"), "mutating a copy never widens the authority")
  local second = HgssInputBindings.menuKeys()
  Assert.isTrue(second["tab"] == true, "later copies still carry the menu key")
  Assert.isNil(second["m"], "later copies never see an earlier copy mutation")
end

return T
