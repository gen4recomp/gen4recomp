-- Game-local physical button alias authority for HGSS A/confirm and
-- B/cancel semantics. Field gameplay and the Oak-hosted naming screen share
-- this module so their keyboard aliases cannot drift apart again. Gamepad
-- buttons keep their existing host mapping (south is action, east is
-- cancel) and are not part of these keyboard lookups.

local FieldPresentation = require("data.manifests.field_presentation")

---@class HgssInputBindings
local HgssInputBindings = {}

---@param list table<string, unknown>?
---@param what string
---@return table<string, boolean>
local function buildSet(list, what)
  assert(type(list) == "table", "field presentation input " .. what .. " aliases are required")
  local set = {}
  for _, key in ipairs(list) do
    assert(type(key) == "string" and key ~= "", "field presentation input " .. what .. " aliases must be keys")
    set[key] = true
  end
  return set
end

local input = assert(
  type(FieldPresentation) == "table" and FieldPresentation.input,
  "field presentation input bindings are required"
)
assert(type(input) == "table", "field presentation input bindings are required")
local ACTION_KEYS = buildSet(input.action, "action")
local CANCEL_KEYS = buildSet(input.cancel, "cancel")

---@param key string
---@return boolean
function HgssInputBindings.isActionKey(key)
  return ACTION_KEYS[key] == true
end

---@param key string
---@return boolean
function HgssInputBindings.isCancelKey(key)
  return CANCEL_KEYS[key] == true
end

---@return table<string, boolean> a fresh copy; callers may not mutate the authority
function HgssInputBindings.actionKeys()
  local copy = {}
  for key in pairs(ACTION_KEYS) do
    copy[key] = true
  end
  return copy
end

---@return table<string, boolean> a fresh copy; callers may not mutate the authority
function HgssInputBindings.cancelKeys()
  local copy = {}
  for key in pairs(CANCEL_KEYS) do
    copy[key] = true
  end
  return copy
end

return HgssInputBindings
