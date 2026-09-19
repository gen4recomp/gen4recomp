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

function T.tests.shared_lookups_agree_with_accessor_copies_for_every_group()
  Assert.isTrue(BINDINGS_REQUIRE_OK, "the shared binding authority exists for field, naming, and menu")
  local groups = {
    {
      aliases = ACTION_ALIASES,
      isKey = HgssInputBindings.isActionKey,
      keys = HgssInputBindings.actionKeys,
      what = "action",
    },
    {
      aliases = CANCEL_ALIASES,
      isKey = HgssInputBindings.isCancelKey,
      keys = HgssInputBindings.cancelKeys,
      what = "cancel",
    },
    { aliases = MENU_ALIASES, isKey = HgssInputBindings.isMenuKey, keys = HgssInputBindings.menuKeys, what = "menu" },
  }
  for _, group in ipairs(groups) do
    local copy = group.keys()
    for _, key in ipairs(group.aliases) do
      Assert.isTrue(group.isKey(key), key .. " lookup resolves to " .. group.what)
      Assert.isTrue(copy[key] == true, key .. " copy carries " .. group.what)
    end
    for _, key in ipairs({ "z", "x", "m" }) do
      Assert.isFalse(group.isKey(key), key .. " lookup stays inert for " .. group.what)
      Assert.isNil(copy[key], key .. " copy stays inert for " .. group.what)
    end
  end
end

function T.tests.action_and_cancel_copies_stay_independent_of_the_shared_authority()
  Assert.isTrue(BINDINGS_REQUIRE_OK, "the shared binding authority exists for field, naming, and menu")
  local action = HgssInputBindings.actionKeys()
  action["space"] = nil
  action["z"] = true
  Assert.isTrue(HgssInputBindings.isActionKey("space"), "mutating an action copy never changes the authority")
  Assert.isFalse(HgssInputBindings.isActionKey("z"), "mutating an action copy never widens the authority")
  local actionLater = HgssInputBindings.actionKeys()
  Assert.isTrue(actionLater["space"] == true, "later action copies still carry the confirm key")
  Assert.isNil(actionLater["z"], "later action copies never see an earlier copy mutation")
  local cancel = HgssInputBindings.cancelKeys()
  cancel["escape"] = nil
  cancel["x"] = true
  Assert.isTrue(HgssInputBindings.isCancelKey("escape"), "mutating a cancel copy never changes the authority")
  Assert.isFalse(HgssInputBindings.isCancelKey("x"), "mutating a cancel copy never widens the authority")
  local cancelLater = HgssInputBindings.cancelKeys()
  Assert.isTrue(cancelLater["escape"] == true, "later cancel copies still carry the cancel key")
  Assert.isNil(cancelLater["x"], "later cancel copies never see an earlier copy mutation")
end

function T.tests.post_load_manifest_edits_never_reach_lookups_or_copies()
  Assert.isTrue(BINDINGS_REQUIRE_OK, "the shared binding authority exists for field, naming, and menu")
  Assert.isTrue(
    type(Manifest.input) == "table" and type(Manifest.input.action) == "table",
    "the manifest publishes action aliases"
  )
  local savedAction = Manifest.input.action
  Manifest.input.action = { "m" }
  local ok, err = pcall(function()
    Assert.isTrue(HgssInputBindings.isActionKey("space"), "lookups keep serving the load-time confirm key")
    Assert.isFalse(HgssInputBindings.isActionKey("m"), "post-load manifest edits never widen the authority")
    local copy = HgssInputBindings.actionKeys()
    Assert.isTrue(copy["space"] == true, "copies keep serving the load-time confirm key")
    Assert.isNil(copy["m"], "copies never pick up post-load manifest edits")
  end)
  Manifest.input.action = savedAction
  if not ok then
    error(err)
  end
  Assert.isTrue(HgssInputBindings.isActionKey("space"), "the manifest is restored after the stability check")
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
