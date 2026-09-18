-- The shared HGSS physical A/B binding authority covers the field and
-- Oak-hosted naming keys from one manifest source.

local Assert = require("tests.support.Assert")

local T = { tests = {} }

local BINDINGS_REQUIRE_OK, HgssInputBindings = pcall(require, "game.hgss.src.HgssInputBindings")
local Manifest = require("data.manifests.field_presentation")

function T.tests.manifest_action_aliases_cover_the_shared_confirm_keys()
  local action = assert(Manifest.input and Manifest.input.action, "the manifest publishes action aliases")
  local seen = {}
  for _, key in ipairs(action) do
    seen[key] = true
  end
  for _, key in ipairs({ "z", "space", "return", "kpenter" }) do
    Assert.isTrue(seen[key] == true, "action aliases include " .. key)
  end
end

function T.tests.manifest_cancel_aliases_cover_the_shared_delete_keys()
  local cancel = assert(Manifest.input and Manifest.input.cancel, "the manifest publishes cancel aliases")
  local seen = {}
  for _, key in ipairs(cancel) do
    seen[key] = true
  end
  for _, key in ipairs({ "x", "backspace" }) do
    Assert.isTrue(seen[key] == true, "cancel aliases include " .. key)
  end
end

function T.tests.shared_lookup_resolves_action_and_cancel_without_overlap()
  Assert.isTrue(BINDINGS_REQUIRE_OK, "the shared binding authority exists for field and naming")
  for _, key in ipairs({ "z", "space", "return", "kpenter" }) do
    Assert.isTrue(HgssInputBindings.isActionKey(key), key .. " resolves to action")
    Assert.isFalse(HgssInputBindings.isCancelKey(key), key .. " never resolves to cancel")
  end
  for _, key in ipairs({ "x", "backspace" }) do
    Assert.isTrue(HgssInputBindings.isCancelKey(key), key .. " resolves to cancel")
    Assert.isFalse(HgssInputBindings.isActionKey(key), key .. " never resolves to action")
  end
  Assert.isFalse(HgssInputBindings.isActionKey("escape"), "escape stays host behavior, never action")
  Assert.isFalse(HgssInputBindings.isCancelKey("escape"), "escape stays host behavior, never cancel")
end

return T
