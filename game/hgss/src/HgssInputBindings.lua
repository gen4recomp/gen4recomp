-- Game-local physical button alias authority for HGSS A/confirm, B/cancel,
-- and X/menu semantics. Field gameplay, the Oak-hosted naming screen, and
-- the Main Menu share this module so their keyboard aliases cannot drift
-- apart again. Gamepad buttons keep their existing host mapping (south is
-- action, east is cancel) and are not part of these keyboard lookups.

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

-- The bindings are application configuration validated once when this module
-- loads. Every lookup and accessor shares those module-local sets, so field
-- snapshots and direct callers observe one identical authority for the
-- process lifetime. Mutating the manifest after load is unsupported and has
-- no effect.
local input = assert(
  type(FieldPresentation) == "table" and FieldPresentation.input,
  "field presentation input bindings are required"
)
assert(type(input) == "table", "field presentation input bindings are required")

local ACTION_KEYS = buildSet(assert(input.action, "field presentation input action aliases are required"), "action")
local CANCEL_KEYS = buildSet(assert(input.cancel, "field presentation input cancel aliases are required"), "cancel")
local MENU_KEYS = buildSet(assert(input.menu, "field presentation input menu aliases are required"), "menu")

---@param set table<string, boolean>
---@return table<string, boolean>
local function copySet(set)
  local copy = {}
  for key in pairs(set) do
    copy[key] = true
  end
  return copy
end

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

---@param key string
---@return boolean
function HgssInputBindings.isMenuKey(key)
  return MENU_KEYS[key] == true
end

---@return table<string, boolean> a fresh copy; callers may not mutate the authority
function HgssInputBindings.actionKeys()
  return copySet(ACTION_KEYS)
end

---@return table<string, boolean> a fresh copy; callers may not mutate the authority
function HgssInputBindings.cancelKeys()
  return copySet(CANCEL_KEYS)
end

---@return table<string, boolean> a fresh copy; callers may not mutate the authority
function HgssInputBindings.menuKeys()
  return copySet(MENU_KEYS)
end

return HgssInputBindings
